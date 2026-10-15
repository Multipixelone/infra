import com.google.gson.Gson;
import com.mojang.authlib.GameProfile;
import io.netty.channel.embedded.EmbeddedChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import net.minecraft.network.chat.Component;
import net.minecraft.network.protocol.PacketFlow;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ClientInformation;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.server.network.CommonListenerCookie;
import net.minecraft.server.network.ServerGamePacketListenerImpl;
import net.minecraft.server.players.NameAndId;
import net.minecraft.stats.Stats;
import org.bukkit.Bukkit;
import org.bukkit.craftbukkit.CraftServer;
import org.bukkit.plugin.java.JavaPlugin;

/** Disposable players, with no client connection or external service access. */
public final class JoinTipsProbe extends JavaPlugin {
    private MinecraftServer server;
    private List<String> tips;
    private List<Integer> tipEvents;
    private String welcome;
    private int welcomeEvents;
    private static final String SEEN = "infra.join_tips.seen";

    private static final class CapturePlayer extends ServerPlayer {
        final List<String> messages = new ArrayList<>();
        final List<Component> packets = new ArrayList<>();

        CapturePlayer(MinecraftServer server, String name) {
            super(server, server.overworld(), new GameProfile(
                    UUID.nameUUIDFromBytes(("OfflinePlayer:" + name).getBytes(StandardCharsets.UTF_8)), name),
                    ClientInformation.createDefault());
            net.minecraft.network.Connection connection = new net.minecraft.network.Connection(PacketFlow.SERVERBOUND);
            connection.channel = new EmbeddedChannel();
            connection.address = new java.net.InetSocketAddress("127.0.0.1", 12345);
            this.connection = new ServerGamePacketListenerImpl(server, connection, this,
                    CommonListenerCookie.createInitial(getGameProfile(), false));
        }

        @Override public void sendSystemMessage(Component component) {
            packets.add(component);
            messages.addAll(List.of(component.getString().split("\n", -1)));
        }

        @Override public void sendSystemMessage(Component component, boolean overlay) {
            if (!overlay) sendSystemMessage(component);
        }
    }

    private void check(boolean condition, String label) {
        if (!condition) throw new AssertionError(label);
        getLogger().info("PASS " + label);
    }

    private CapturePlayer player(String name) {
        CapturePlayer player = new CapturePlayer(server, name);
        server.getPlayerList().getPlayers().add(player);
        server.getPlayerList().getPlayersByUUID().put(player.getUUID(), player);
        return player;
    }

    private void command(String command) {
        server.getCommands().performPrefixedCommand(server.createCommandSourceStack(), command);
    }

    private void function(CapturePlayer player, String name) {
        server.getCommands().performPrefixedCommand(server.createCommandSourceStack()
                .withEntity(player), "function infra:join_tips/" + name);
    }

    private int score(CapturePlayer player, String name) {
        var objective = server.getScoreboard().getObjective(name);
        var score = server.getScoreboard().getPlayerScoreInfo(player, objective);
        return score == null ? -1 : score.value();
    }

    private void returning(CapturePlayer player, String label) {
        check(player.messages.size() == 2, label + " exactly two private lines: " + player.messages);
        check(player.messages.get(0).equals("· Welcome back, " + player.getPlainTextName() + "!"), label + " welcome above tip");
        int choice = score(player, "ijt_tip");
        check(choice >= 1 && choice <= tips.size(), label + " actual random value in range");
        check(player.messages.get(1).equals(tips.get(choice - 1)), label + " one matching random tip");
        check(player.packets.size() == 2, label + " exactly two tellraw packets");
        // Resolved selector names retain Minecraft's native name click/hover.
        interactions(player.packets.get(0), 1);
        interactions(player.packets.get(1), tipEvents.get(choice - 1));
        check(score(player, "ijt_leave") == 0, label + " leave counter consumed");
        player.messages.clear();
        player.packets.clear();
    }

    private int[] eventCounts(Component component) {
        int clicks = component.getStyle().getClickEvent() == null ? 0 : 1;
        int hovers = component.getStyle().getHoverEvent() == null ? 0 : 1;
        for (var child : component.getSiblings()) {
            var counts = eventCounts(child);
            clicks += counts[0];
            hovers += counts[1];
        }
        return new int[] { clicks, hovers };
    }

    private void interactions(Component component, int expected) {
        var counts = eventCounts(component);
        check(counts[0] == expected && counts[1] == expected,
                "server parsed all click/hover events: " + counts[0] + "/" + counts[1] + " expected " + expected);
        check(component.getStyle().getColor().getValue() == 0xa6adc8, "server parsed exact muted root color");
    }

    private void quiet(CapturePlayer player, String label) {
        check(player.messages.isEmpty(), label + " emits no messages: " + player.messages);
    }

    private void gradientColors(net.kyori.adventure.text.Component component,
            net.kyori.adventure.text.format.TextColor inherited, List<String> colors) {
        var color = component.color() == null ? inherited : component.color();
        if (component instanceof net.kyori.adventure.text.TextComponent text) {
            text.content().codePoints().forEach(character -> colors.add(color.asHexString().toLowerCase(java.util.Locale.ROOT)));
        }
        for (var child : component.children()) gradientColors(child, color, colors);
    }

    private void firstBoot() throws Exception {
        check(server.getScoreboard().getObjective("ijt_leave") != null && server.getScoreboard().getObjective("ijt_tip") != null,
                "automatic load tag initializes objectives before players join");
        var fresh = player("FreshProbe");
        var historicalTime = player("TimeProbe");
        var historicalLeave = player("LeaveProbe");
        var tagged = player("TaggedProbe");
        historicalTime.getStats().setValue(historicalTime, Stats.CUSTOM.get(Stats.PLAY_TIME), 7200);
        historicalTime.getStats().save();
        historicalLeave.getStats().setValue(historicalLeave, Stats.CUSTOM.get(Stats.LEAVE_GAME), 1);
        historicalLeave.getStats().save();
        tagged.addTag(SEEN);
        check(fresh.getStats().getValue(Stats.CUSTOM.get(Stats.PLAY_TIME)) == 0, "fresh saved play time is zero");
        check(score(historicalTime, "ijt_leave") == -1 && score(historicalLeave, "ijt_leave") == -1,
                "historical players have no newly created scoreboard value");
        getLogger().info("SELECTOR_STATE players=" + server.getPlayerList().getPlayers().size() + " freshAlive=" + fresh.isAlive() + " removed=" + fresh.isRemoved());
        command("execute as @a run tellraw @s {\"text\":\"SELECTOR_PROBE\"}");
        check(fresh.messages.equals(List.of("SELECTOR_PROBE")), "synthetic player participates in actual @a selector: " + fresh.messages);
        for (var player : List.of(fresh, historicalTime, historicalLeave, tagged)) {
            player.messages.clear();
            player.packets.clear();
        }
        command("function infra:join_tips/tick");
        check(String.join("\n", fresh.messages).equals(welcome), "fresh player receives only exact six-line Getting Started block: " + fresh.messages + " expected " + welcome);
        check(fresh.messages.size() == 6, "fresh has six lines");
        check(fresh.packets.size() == 1, "first join is one six-line packet");
        interactions(fresh.packets.get(0), welcomeEvents);
        check(fresh.entityTags().contains(SEEN), "fresh player marked persistently");
        fresh.messages.clear();
        fresh.packets.clear();
        returning(historicalTime, "historical play time");
        returning(historicalLeave, "historical leave stat");
        returning(tagged, "pre-existing tag");
        // All players share the same tick invocation: captured destinations prove privacy.
        for (int index = 0; index < 10; index++) command("function infra:join_tips/tick");
        for (var player : List.of(fresh, historicalTime, historicalLeave, tagged)) quiet(player, "later ticks " + player.getPlainTextName());
        command("function infra:join_tips/load");
        command("function infra:join_tips/tick");
        quiet(fresh, "load preserves consumed join");
        quiet(tagged, "load does not broadcast");
        var respawn = new CapturePlayer(server, "FreshProbe");
        respawn.restoreFrom(fresh, false);
        server.getPlayerList().getPlayers().remove(fresh);
        server.getPlayerList().getPlayers().add(respawn);
        server.getPlayerList().getPlayersByUUID().put(respawn.getUUID(), respawn);
        command("function infra:join_tips/tick");
        quiet(respawn, "actual respawn state copy");
        // Use Paper's real disconnect hook, which awards LEAVE_GAME and saves the player.
        server.getPlayerList().remove(respawn);
        check(score(respawn, "ijt_leave") == 1, "Paper PlayerList.remove increments criterion on real leave award");
        var reconnect = player("FreshProbe");
        command("function infra:join_tips/tick");
        returning(reconnect, "reconnect");
        quiet(historicalTime, "another player's reconnect stays private");
        // Each authored branch is runnable, independent of random sampling luck.
        for (int index = 1; index <= tips.size(); index++) {
            function(reconnect, "tips/" + index);
            check(reconnect.messages.equals(List.of(tips.get(index - 1))), "tip branch " + index);
            interactions(reconnect.packets.get(0), tipEvents.get(index - 1));
            reconnect.messages.clear();
            reconnect.packets.clear();
        }
        for (int index = 0; index < 40; index++) {
            function(reconnect, "returning");
            returning(reconnect, "random sample " + index);
        }
        server.getPlayerList().remove(reconnect);
        check(score(reconnect, "ijt_leave") == 1, "pending leave saved for clean restart");
        for (var player : List.of(historicalTime, historicalLeave, tagged)) server.getPlayerList().remove(player);
        command("save-all flush");
        Files.writeString(Path.of("join-tips-phase-two"), "ready");
        getLogger().info("JOIN_TIPS_PHASE_ONE_PASS");
    }

    private void secondBoot() {
        var player = player("FreshProbe");
        check(score(player, "ijt_leave") == 1, "leave scoreboard persisted across clean restart");
        check(player.getStats().getValue(Stats.CUSTOM.get(Stats.LEAVE_GAME)) >= 2, "saved historical stats persisted");
        var saved = server.getPlayerList().loadPlayerData(new NameAndId(player.getGameProfile())).orElseThrow();
        var tags = saved.getListOrEmpty("Tags");
        boolean seen = false;
        for (int index = 0; index < tags.size(); index++) seen |= tags.getStringOr(index, "").equals(SEEN);
        check(seen, "persistent classification tag saved in player data");
        command("function infra:join_tips/tick");
        returning(player, "clean restart reconnect");
        command("function infra:join_tips/tick");
        quiet(player, "clean restart subsequent tick");
        var reload = server.reloadResources(server.getPackRepository().getSelectedIds());
        server.managedBlock(reload::isDone);
        reload.join();
        command("function infra:join_tips/tick");
        quiet(player, "actual datapack reload preserves consumed join");
        server.getPlayerList().remove(player);
        getLogger().info("JOIN_TIPS_PHASE_TWO_PASS");
    }

    @Override public void onEnable() {
        Bukkit.getScheduler().runTaskLater(this, () -> {
            try {
                server = ((CraftServer) Bukkit.getServer()).getServer();
                var expectations = new Gson().fromJson(new String(getResource("expectations.json").readAllBytes(), StandardCharsets.UTF_8), com.google.gson.JsonObject.class);
                tips = expectations.getAsJsonArray("tips").asList().stream().map(value -> value.getAsString()).toList();
                tipEvents = expectations.getAsJsonArray("tip_events").asList().stream().map(value -> value.getAsInt()).toList();
                welcome = expectations.get("welcome").getAsString();
                welcomeEvents = expectations.get("welcome_events").getAsInt();
                var actualColors = new ArrayList<String>();
                gradientColors(net.kyori.adventure.text.minimessage.MiniMessage.miniMessage().deserialize(
                        "<bold><gradient:#cba6f7:#f5c2e7:#fab387>Finn's Survival</gradient></bold>"), null, actualColors);
                var expectedColors = expectations.getAsJsonArray("gradient_colors").asList().stream().map(value -> value.getAsString()).toList();
                check(actualColors.equals(expectedColors), "exact welcome gradient matches pinned MiniMessage renderer: " + actualColors);
                if (Files.exists(Path.of("join-tips-phase-two"))) secondBoot(); else firstBoot();
            } catch (Throwable failure) {
                getLogger().severe("JOIN_TIPS_PROBE_FAIL");
                failure.printStackTrace();
            } finally {
                Bukkit.getScheduler().runTask(this, Bukkit::shutdown);
            }
        }, 20L);
    }
}

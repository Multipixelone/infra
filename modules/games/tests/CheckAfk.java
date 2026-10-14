import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.function.Consumer;
import net.flectone.pulse.config.Command;
import net.flectone.pulse.config.Integration;
import net.flectone.pulse.config.Localization;
import net.flectone.pulse.config.Message;
import net.flectone.pulse.config.Permission;
import net.flectone.pulse.constant.SettingText;
import net.flectone.pulse.dispatcher.MessageDispatcher;
import net.flectone.pulse.file.FileFacade;
import net.flectone.pulse.library.apache.lang3.tuple.Pair;
import net.flectone.pulse.library.jackson.databind.PropertyNamingStrategies;
import net.flectone.pulse.library.jackson.dataformat.yaml.YAMLMapper;
import net.flectone.pulse.model.entity.FPlayer;
import net.flectone.pulse.module.integration.placeholderapi.BukkitPlaceholderAPIIntegration;
import net.flectone.pulse.module.message.afk.AfkModuleImpl;
import net.flectone.pulse.module.message.afk.listener.BukkitAfkListener;
import net.flectone.pulse.platform.adapter.PlatformPlayerAdapter;
import net.flectone.pulse.platform.adapter.PlatformPlayerAdapter.Coordinates;
import net.flectone.pulse.platform.controller.ModuleController;
import net.flectone.pulse.platform.registry.ListenerRegistry;
import net.flectone.pulse.platform.registry.ProxyRegistry;
import net.flectone.pulse.platform.sender.SoundPlayer;
import net.flectone.pulse.scheduler.SchedulerRunnable;
import net.flectone.pulse.scheduler.TaskScheduler;
import net.flectone.pulse.service.FPlayerService;
import net.flectone.pulse.service.SocialService;
import org.bukkit.OfflinePlayer;
import org.bukkit.entity.Player;
import org.bukkit.event.player.AsyncPlayerChatEvent;

// Parse the generated files with FlectonePulse's own relocated Jackson schema,
// then run the pinned module and listener with isolated platform boundaries.
// Backdate its coordinate samples instead of waiting five minutes or starting
// Paper. The state transitions, command and expansion remain plugin code.
public class CheckAfk {
    @SuppressWarnings("unchecked")
    public static void main(String[] args) throws Exception {
        var mapper = YAMLMapper.builder().propertyNamingStrategy(PropertyNamingStrategies.SNAKE_CASE).build();
        // Character input also preserves the bundled symbol module's Unicode;
        // SnakeYAML's byte reader mishandles surrogate pairs at buffer edges.
        var message = mapper.readValue(Files.readString(Path.of(args[0])), Message.class);
        var command = mapper.readValue(Files.readString(Path.of(args[1])), Command.class);
        var integration = mapper.readValue(Files.readString(Path.of(args[2])), Integration.class);
        var localization = mapper.readValue(Files.readString(Path.of(args[3])), Localization.class);
        var permission = mapper.readValue(Files.readString(Path.of(args[4])), Permission.class);
        ReadCarbon.require(message.afk().delay() * 50 == 300_000, "AFK delay is not five minutes");
        ReadCarbon.require(command.afk().enable() && integration.placeholderapi().enable(), "AFK bridge disabled");
        var files = ReadCarbon.stub(FileFacade.class, (name, values) -> switch (name) {
            case "message" -> message;
            case "command" -> command;
            case "permission" -> permission;
            case "localization" -> localization;
            default -> null;
        });
        for (String account : new String[]{"JavaFriend", ".Bedrock_Friend"}) {
            var player = FPlayer.builder().id(100).uuid(UUID.randomUUID()).name(account).online(true).build();
            var state = new HashMap<UUID, String>();
            var social = ReadCarbon.stub(SocialService.class, (name, values) -> switch (name) {
                case "getSetting" -> values[1] == SettingText.LOCALE ? "en_us" : state.get(((FPlayer) values[0]).uuid());
                case "saveSetting" -> {
                    UUID id = ((FPlayer) values[0]).uuid();
                    if (values[2] == null) state.remove(id); else state.put(id, (String) values[2]);
                    yield null;
                }
                case "isVanished" -> false;
                default -> null;
            });
            var players = ReadCarbon.stub(FPlayerService.class, (name, values) -> player);
            var position = new Coordinates[]{new Coordinates(10, 64, 20, 0, 0)};
            var adapter = ReadCarbon.stub(PlatformPlayerAdapter.class, (name, values) -> position[0]);
            var controller = ReadCarbon.stub(ModuleController.class, (name, values) -> name.equals("isEnable"));
            var tick = new Consumer[1];
            var scheduler = ReadCarbon.stub(TaskScheduler.class, (name, values) -> {
                if (name.equals("runPlayerAsyncTimer")) {
                    tick[0] = (Consumer<FPlayer>) values[0];
                    ReadCarbon.require(values[1].equals(20L), "AFK ticker must run every second");
                } else if (name.equals("runAsync")) {
                    try { ((SchedulerRunnable) values[0]).run(); }
                    catch (Exception error) { throw new RuntimeException(error); }
                }
                return CompletableFuture.completedFuture(null);
            });
            int[] announcements = {0};
            var dispatcher = ReadCarbon.stub(MessageDispatcher.class, (name, values) -> {
                announcements[0]++; return Set.of(player);
            });
            var listeners = ReadCarbon.stub(ListenerRegistry.class, (name, values) -> null);
            var proxy = ReadCarbon.stub(ProxyRegistry.class, (name, values) -> false);
            var afk = new AfkModuleImpl(files, players, scheduler, adapter, listeners, null,
                dispatcher, controller, null, null, social, proxy);
            afk.onEnable();
            var sampleField = AfkModuleImpl.class.getDeclaredField("playersCoordinates");
            sampleField.setAccessible(true);
            var samples = (Map<UUID, Pair<Long, Coordinates>>) sampleField.get(afk);
            var expansion = ReadTab.empty(BukkitPlaceholderAPIIntegration.class);
            ReadTab.set(BukkitPlaceholderAPIIntegration.class, expansion, "fPlayerService", players);
            ReadTab.set(BukkitPlaceholderAPIIntegration.class, expansion, "socialService", social);
            var offline = ReadCarbon.stub(OfflinePlayer.class, (name, values) -> player.uuid());
            var sounds = ReadCarbon.stub(SoundPlayer.class, (name, values) -> null);
            var toggle = new net.flectone.pulse.module.command.afk.AfkModuleImpl(files, afk, sounds, controller, null, social);
            ReadCarbon.require(expansion.onRequest(offline, "setting_afk_suffix").isEmpty(), "Active player marked AFK");
            toggle.execute(player, null);
            ReadCarbon.require(expansion.onRequest(offline, "setting_afk_suffix").equals("AFK"), "Manual AFK not exported");
            tick[0].accept(player);
            ReadCarbon.require(announcements[0] == 1, "Idle poll repeated manual AFK announcement");
            toggle.execute(player, null);
            ReadCarbon.require(state.isEmpty() && announcements[0] == 2, "Manual toggle did not clear AFK");
            tick[0].accept(player);
            samples.put(player.uuid(), Pair.of(System.currentTimeMillis() - 290_000, position[0]));
            tick[0].accept(player);
            ReadCarbon.require(state.isEmpty(), "Auto-AFK activated before five minutes");
            samples.put(player.uuid(), Pair.of(System.currentTimeMillis() - 301_000, position[0]));
            tick[0].accept(player);
            ReadCarbon.require(expansion.onRequest(offline, "setting_afk_suffix").equals("AFK"), "Automatic AFK not exported");
            tick[0].accept(player);
            ReadCarbon.require(announcements[0] == 3, "Idle poll repeated automatic AFK announcement");
            position[0] = new Coordinates(10.01, 64, 20, 0, 0);
            tick[0].accept(player);
            ReadCarbon.require(state.isEmpty() && announcements[0] == 4, "Movement did not clear AFK");
            toggle.execute(player, null);
            var listener = new BukkitAfkListener(players, afk, toggle, controller, scheduler, social);
            var bukkit = ReadCarbon.stub(Player.class, (name, values) -> player.uuid());
            listener.asyncPlayerChatEvent(new AsyncPlayerChatEvent(true, bukkit, "hello", Set.of()));
            ReadCarbon.require(expansion.onRequest(offline, "setting_afk_suffix").isEmpty(), "Chat did not clear AFK");
            ReadCarbon.require(announcements[0] == 6, "Chat transition announcement missing");
            for (boolean status : new boolean[]{true, false}) {
                String global = afk.localizationFormat(player, FPlayer.UNKNOWN, status).replace("<player>", account);
                var rendered = net.kyori.adventure.text.minimessage.MiniMessage.miniMessage().deserialize(global);
                ReadCarbon.require(ReadTab.plain(rendered).equals("· " + account + (status ? " is now AFK" : " is no longer AFK")), "AFK event failed to render");
                ReadCarbon.require(ReadCarbon.checkText(rendered, null, account, net.kyori.adventure.text.format.TextColor.fromHexString("#cba6f7")), "AFK name palette changed");
                String local = afk.localizationFormat(player, player, status);
                ReadCarbon.require(ReadTab.plain(net.kyori.adventure.text.minimessage.MiniMessage.miniMessage().deserialize(local))
                    .equals(status ? "· You are now AFK" : "· You are no longer AFK"), "Self AFK event failed to render");
            }
            afk.onDisable();
        }
        System.out.println("PASS: pinned FlectonePulse schema, AFK toggle/timer/movement/chat, PAPI state and styled events for Java/Bedrock identities");
    }
}

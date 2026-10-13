import java.lang.reflect.Method;
import java.nio.file.Path;
import java.util.Optional;
import java.util.UUID;
import carbonchat.libs.org.spongepowered.configurate.hocon.HoconConfigurationLoader;
import github.scarsz.discordsrv.util.MessageUtil;
import me.neznamy.tab.platforms.bukkit.BukkitTabPlayer;
import me.neznamy.tab.shared.platform.TabPlayer;
import net.draycia.carbon.api.users.CarbonPlayer;
import net.draycia.carbon.common.command.Commander;
import net.draycia.carbon.common.command.PlayerCommander;
import net.draycia.carbon.common.command.commands.NicknameCommand;
import net.draycia.carbon.common.config.ConfigManager;
import net.draycia.carbon.common.config.PrimaryConfig;
import net.draycia.carbon.common.messages.CarbonMessageRenderer;
import net.draycia.carbon.common.messages.CarbonMessages;
import net.draycia.carbon.common.messages.RenderForTagResolver;
import net.draycia.carbon.common.users.CarbonPlayerCommon;
import net.draycia.carbon.common.users.WrappedCarbonPlayer;
import net.draycia.carbon.paper.users.CarbonPlayerPaper;
import net.kyori.adventure.audience.Audience;
import net.kyori.adventure.text.Component;
import net.kyori.adventure.text.format.TextDecoration;
import net.kyori.adventure.text.minimessage.MiniMessage;
import net.kyori.adventure.text.minimessage.tag.resolver.TagResolver;
import net.kyori.adventure.text.serializer.legacy.LegacyComponentSerializer;
import net.kyori.adventure.text.serializer.plain.PlainTextComponentSerializer;
import org.bukkit.entity.Player;

// Run the pinned nickname command, display-name renderer, Bukkit setter, TAB
// getter and DiscordSRV stripping without starting Paper or connecting a bot.
public class CheckNicknames {
    static final LegacyComponentSerializer legacy = LegacyComponentSerializer.builder()
        .character('§').hexColors().useUnusualXRepeatedCharacterHexFormat().build();
    static String plain(Component value) {
        return PlainTextComponentSerializer.plainText().serialize(value);
    }
    static void safe(Component value) {
        ReadCarbon.require(value.clickEvent() == null && value.hoverEvent() == null
            && value.insertion() == null && value.font() == null, "Unsafe nickname event/font");
        for (TextDecoration decoration : TextDecoration.values())
            ReadCarbon.require(value.decoration(decoration) != TextDecoration.State.TRUE, "Nickname decoration");
        value.children().forEach(CheckNicknames::safe);
    }
    static Method method(Class<?> type, String name, Class<?>... parameters) throws Exception {
        Method method = type.getDeclaredMethod(name, parameters);
        method.setAccessible(true);
        return method;
    }
    public static void main(String[] args) throws Exception {
        var root = HoconConfigurationLoader.builder().path(Path.of(args[0])).build().load();
        var settings = root.node("nickname-settings").get(PrimaryConfig.NicknameSettings.class);
        ReadCarbon.require(settings.minLength() == 3 && settings.maxLength() == 16, "Wrong visible limits");
        var primary = new PrimaryConfig();
        ReadTab.set(PrimaryConfig.class, primary, "nicknameSettings", settings);
        var config = ReadTab.empty(ConfigManager.class);
        ReadTab.set(ConfigManager.class, config, "primaryConfig", primary);
        var errors = new String[1];
        var messages = ReadCarbon.stub(CarbonMessages.class, (name, values) -> {
            if (name.startsWith("nicknameError")) errors[0] = name;
            return null;
        });
        var command = new NicknameCommand(null, messages, null, config);
        var apply = method(NicknameCommand.class, "applyNickname", Commander.class, CarbonPlayer.class, String.class);
        var reset = method(NicknameCommand.class, "resetNickname", Commander.class, CarbonPlayer.class);
        var write = method(CarbonPlayerPaper.class, "lambda$applyDisplayNameToBukkit$1", Player.class, Component.class);
        for (String account : new String[]{"JavaFriend", ".Bedrock_Friend", ".1234567890123456"}) {
            var common = new CarbonPlayerCommon(account, UUID.randomUUID());
            ReadTab.set(CarbonPlayerCommon.class, common, "config", config);
            var resolver = ReadTab.empty(RenderForTagResolver.class);
            var renderer = new CarbonMessageRenderer(values -> resolver) {
                protected Component render(Audience audience, String format, TagResolver.Builder tags) {
                    return MiniMessage.miniMessage().deserialize(format, tags.build());
                }
            };
            ReadTab.set(CarbonPlayerCommon.class, common, "messageRenderer", renderer);
            var display = new Component[]{Component.text(account)};
            var bukkit = ReadCarbon.stub(Player.class, (name, values) -> switch (name) {
                case "displayName" -> {
                    if (values == null || values.length == 0) yield display[0];
                    display[0] = values[0] == null ? Component.text(account) : (Component) values[0];
                    yield null;
                }
                case "getDisplayName" -> legacy.serialize(display[0]);
                case "playerListName" -> throw new AssertionError("Carbon competed with TAB");
                default -> null;
            });
            var paper = ReadTab.empty(CarbonPlayerPaper.class);
            ReadTab.set(WrappedCarbonPlayer.class, paper, "carbonPlayerCommon", common);
            var wrapped = new WrappedCarbonPlayer(common) {
                protected Optional<Component> platformDisplayName() { return Optional.of(display[0]); }
                public double distanceSquaredFrom(CarbonPlayer other) { return 0; }
                public boolean sameWorldAs(CarbonPlayer other) { return true; }
                public Component createItemHoverComponent(net.draycia.carbon.api.util.InventorySlot slot) { return null; }
                public java.util.Locale locale() { return java.util.Locale.US; }
                public void sendMessageAsPlayer(String message) { }
                public boolean online() { return true; }
                public boolean vanished() { return false; }
            };
            var target = ReadCarbon.stub(CarbonPlayer.class, (name, values) -> switch (name) {
                case "uuid" -> common.uuid();
                case "username" -> account;
                case "nickname" -> {
                    if (values == null || values.length == 0) yield common.nickname();
                    common.nickname((Component) values[0]);
                    try {
                        write.invoke(paper, bukkit, values[0] == null ? null : wrapped.displayName());
                    } catch (ReflectiveOperationException error) { throw new RuntimeException(error); }
                    yield null;
                }
                default -> null;
            });
            var sender = ReadCarbon.stub(PlayerCommander.class, (name, values) -> switch (name) {
                case "carbonPlayer" -> target;
                case "hasPermission" -> values[0].equals("carbon.nickname.tags.color")
                    || values[0].equals("carbon.nickname.tags.reset");
                default -> null;
            });
            var tab = ReadTab.empty(BukkitTabPlayer.class);
            ReadTab.set(TabPlayer.class, tab, "player", bukkit);
            for (String input : new String[]{"<red>Finn", "<#55aaff>Abc", "<green>1234567890123456", "<red>A<reset>bc"}) {
                errors[0] = null;
                apply.invoke(command, sender, target, input);
                ReadCarbon.require(errors[0] == null, "Valid nickname rejected: " + input);
                safe(display[0]);
                ReadCarbon.require(common.needsSave(), "Nickname did not mark persistent state dirty");
                ReadCarbon.require(!tab.getDisplayName().equals(plain(display[0])), "Colour was lost on Bukkit/TAB path");
                ReadCarbon.require(MessageUtil.strip(tab.getDisplayName()).equals(plain(display[0])), "Discord retained colour codes");
                Component previous = display[0];
                for (String invalid : new String[]{"<red>ab", "<red>12345678901234567", "<red>AdMiN", "owner", "moderator",
                    "has space", "&cFinn", "<obfuscated>Finn", "<bold>Finn", "<click:run_command:'/op me'>Finn",
                    "<hover:show_text:'test'>Finn", "<gradient:red:blue>Finn", "<newline>Finn", "<font:minecraft:alt>Finn"}) {
                    errors[0] = null;
                    apply.invoke(command, sender, target, invalid);
                    ReadCarbon.require(errors[0] != null && previous.equals(display[0]), "Unsafe nickname accepted: " + invalid);
                }
            }
            reset.invoke(command, sender, target);
            ReadCarbon.require(!common.hasNickname(), "Reset retained nickname");
            ReadCarbon.require(tab.getDisplayName().equals(account), "TAB reset lost account name");
            ReadCarbon.require(MessageUtil.strip(bukkit.getDisplayName()).equals(account), "Discord reset lost account name/prefix");
        }
        System.out.println("PASS: actual Carbon nickname validation, colour-only rendering, persistent state, Bukkit/TAB and Discord stripping, Java/Bedrock reset");
    }
}

import java.lang.reflect.Proxy;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.zip.ZipFile;
import io.papermc.paper.plugin.configuration.PluginMeta;
import io.papermc.paper.plugin.provider.classloader.ConfiguredPluginClassLoader;
import io.papermc.paper.plugin.provider.classloader.PluginClassLoaderGroup;
import org.bukkit.Bukkit;
import org.bukkit.Server;
import org.bukkit.OfflinePlayer;
import org.bukkit.plugin.Plugin;
import org.bukkit.plugin.PluginManager;
import org.bukkit.plugin.java.JavaPlugin;
import org.yaml.snakeyaml.Yaml;
import github.scarsz.configuralize.DynamicConfig;
import github.scarsz.discordsrv.DiscordSRV;
import github.scarsz.discordsrv.dependencies.jda.api.JDA;
import github.scarsz.discordsrv.dependencies.jda.api.entities.*;
import github.scarsz.discordsrv.dependencies.jda.api.events.message.guild.GuildMessageReceivedEvent;
import github.scarsz.discordsrv.dependencies.kyori.adventure.text.serializer.gson.GsonComponentSerializer;
import github.scarsz.discordsrv.listeners.DiscordChatListener;
import github.scarsz.discordsrv.objects.managers.AccountLinkManager;
import net.draycia.carbon.paper.integration.dsrv.DSRVListener;
import net.kyori.adventure.text.Component;
import net.kyori.adventure.text.TextComponent;
import net.kyori.adventure.text.format.TextColor;
import net.kyori.adventure.text.serializer.plain.PlainTextComponentSerializer;

// Run the pinned formatter with a real Paper plugin classloader contract and
// API fixtures. No plugin startup, bot, credentials, server or network is used.
public class CheckDiscordFormats {
    public static class Loader extends URLClassLoader implements ConfiguredPluginClassLoader {
        private JavaPlugin plugin;
        public Loader(URL jar, URL classes) {
            super(new URL[]{jar, classes}, CheckDiscordFormats.class.getClassLoader());
        }
        protected Class<?> loadClass(String name, boolean resolve) throws ClassNotFoundException {
            synchronized (getClassLoadingLock(name)) {
                Class<?> type = findLoadedClass(name);
                if (type == null && (name.startsWith("github.scarsz.") || name.startsWith("CheckDiscordFormats$Runner")))
                    type = findClass(name);
                if (type == null) type = super.loadClass(name, false);
                if (resolve) resolveClass(type);
                return type;
            }
        }
        public Class<?> loadClass(String name, boolean resolve, boolean global, boolean libraries) throws ClassNotFoundException {
            return loadClass(name, resolve);
        }
        public PluginMeta getConfiguration() { return null; }
        public PluginClassLoaderGroup getGroup() { return null; }
        public JavaPlugin getPlugin() { return plugin; }
        public void init(JavaPlugin plugin) { this.plugin = plugin; }
    }
    public static <T> T empty(Class<T> type) throws Exception { return ReadTab.empty(type); }
    public static void set(Class<?> type, Object target, String field, Object value) throws Exception {
        ReadTab.set(type, target, field, value);
    }
    public static void require(boolean value, String message) { ReadCarbon.require(value, message); }
    public static Component bridge(String json) throws Exception {
        var component = GsonComponentSerializer.gson().deserialize(json);
        var method = DSRVListener.class.getDeclaredMethod("fromDsrv",
            github.scarsz.discordsrv.dependencies.kyori.adventure.text.Component.class);
        method.setAccessible(true);
        return (Component) method.invoke(empty(DSRVListener.class), component);
    }
    public static void verify(Component component, String name, String reply, String body, boolean role) {
        String expected = "[Discord] " + name + reply + " › " + body;
        String plain = PlainTextComponentSerializer.plainText().serialize(component);
        require(expected.equals(plain), "Unresolved or wrong incoming format: " + plain);
        require(!hasCommand(component), "A Discord name created a command click event");
        require(ReadCarbon.checkText(component, null, name, TextColor.fromHexString("#cba6f7")), "Missing sender");
        require(ReadCarbon.checkText(component, null, "›", TextColor.fromHexString("#a6adc8")), "Missing separator");
        require(ReadCarbon.checkText(component, null, body, TextColor.fromHexString("#cdd6f4")), "Missing body");
        require(hasRole(component) == role, "Discord role did not stay in sender hover");
        require(!plain.contains("mod"), "Discord role became a visible rank badge");
    }
    static boolean hasRole(Component component) {
        if (component instanceof TextComponent text && component.hoverEvent() != null
                && component.hoverEvent().value() instanceof Component hover
                && PlainTextComponentSerializer.plainText().serialize(hover).equals("Discord role: mod"))
            return true;
        return component.children().stream().anyMatch(CheckDiscordFormats::hasRole);
    }
    static boolean hasCommand(Component component) {
        return (component.clickEvent() != null && component.clickEvent().action()
            == net.kyori.adventure.text.event.ClickEvent.Action.RUN_COMMAND)
            || component.children().stream().anyMatch(CheckDiscordFormats::hasCommand);
    }
    public static void main(String[] args) throws Exception {
        var classes = CheckDiscordFormats.class.getProtectionDomain().getCodeSource().getLocation();
        try (var loader = new Loader(Path.of(args[0]).toUri().toURL(), classes)) {
            loader.loadClass("CheckDiscordFormats$Runner").getMethod("run", String[].class)
                .invoke(null, (Object) args);
        }
    }
    public static class Runner {
        interface Calls { Object call(String name, Object[] args); }
        @SuppressWarnings("unchecked")
        static <T> T stub(Class<T> type, Calls calls) {
            return (T) Proxy.newProxyInstance(type.getClassLoader(), new Class<?>[]{type},
                (proxy, method, args) -> calls.call(method.getName(), args));
        }
        public static void run(String[] args) throws Exception {
            var plugin = empty(DiscordSRV.class);
            ((Loader) DiscordSRV.class.getClassLoader()).init(plugin);
            var config = new DynamicConfig();
            var yaml = new Yaml();
            try (var jar = new ZipFile(args[0])) {
                for (String path : new String[]{"config/en.yml", "messages/en.yml"}) {
                    Map<String, Object> defaults = yaml.load(jar.getInputStream(jar.getEntry(path)));
                    defaults.forEach(config::setRuntimeValue);
                }
            }
            for (String path : new String[]{args[1], args[2]}) {
                try (var input = Files.newInputStream(Path.of(path))) {
                    Map<String, Object> values = yaml.load(input);
                    values.forEach(config::setRuntimeValue);
                }
            }
            set(DiscordSRV.class, plugin, "config", config);
            set(DiscordSRV.class, plugin, "discordRegexes", Map.of());
            set(DiscordSRV.class, plugin, "roleAliases", Map.of());
            UUID linkedId = UUID.randomUUID();
            boolean[] linked = {false};
            int[] offlineLookups = {0};
            var accounts = stub(AccountLinkManager.class, (name, values) ->
                name.equals("getUuid") && linked[0] ? linkedId : null);
            set(DiscordSRV.class, plugin, "accountLinkManager", accounts);
            var plugins = stub(PluginManager.class, (name, values) ->
                name.equals("getPlugins") ? new Plugin[0] : null);
            var server = stub(Server.class, (name, values) -> switch (name) {
                case "getPluginManager" -> plugins;
                case "getOfflinePlayer" -> {
                    require(linkedId.equals(values[0]), "Wrong linked account lookup");
                    offlineLookups[0]++;
                    yield stub(OfflinePlayer.class, (n, v) -> null);
                }
                default -> null;
            });
            set(Bukkit.class, null, "server", server);
            var role = stub(Role.class, (name, values) -> switch (name) {
                case "getName" -> "mod";
                case "getId" -> "123456789012345678";
                case "getColorRaw" -> 0xff0000;
                default -> null;
            });
            var jda = stub(JDA.class, (name, values) -> null);
            var channel = stub(TextChannel.class, (name, values) -> switch (name) {
                case "getName" -> "global";
                case "getGuild" -> stub(Guild.class, (n, v) -> null);
                default -> null;
            });
            var author = stub(User.class, (name, values) -> switch (name) {
                case "getName" -> "account_name";
                case "getId" -> "234567890123456789";
                default -> null;
            });
            String[] displayName = {"Finn"};
            var member = stub(Member.class, (name, values) -> name.equals("getEffectiveName") ? displayName[0] : null);
            var replyAuthor = stub(User.class, (name, values) -> switch (name) {
                case "getName" -> "reply_account";
                case "getId" -> "345678901234567890";
                default -> null;
            });
            var replyMember = stub(Member.class, (name, values) -> name.equals("getEffectiveName") ? "Queen" : null);
            var replyMessage = stub(Message.class, (name, values) -> switch (name) {
                case "getAuthor" -> replyAuthor;
                case "getMember" -> replyMember;
                case "getContentRaw" -> "earlier message";
                default -> null;
            });
            boolean[] replying = {false};
            var message = stub(Message.class, (name, values) -> switch (name) {
                case "getIdLong" -> 1L;
                case "getTextChannel" -> channel;
                case "getAuthor" -> author;
                case "getMember" -> member;
                case "getReferencedMessage" -> replying[0] ? replyMessage : null;
                default -> null;
            });
            var event = new GuildMessageReceivedEvent(jda, 1, message);
            var listener = new DiscordChatListener();
            var format = DiscordChatListener.class.getDeclaredMethod("applyFormattingAndConvertToComponent",
                String.class, String.class, GuildMessageReceivedEvent.class, List.class, Role.class, String.class, boolean.class);
            format.setAccessible(true);
            for (boolean isLinked : new boolean[]{false, true}) {
                linked[0] = isLinked;
                for (boolean hasRole : new boolean[]{false, true}) {
                    String template = config.getString(hasRole ? "DiscordToMinecraftChatMessageFormat" : "DiscordToMinecraftChatMessageFormatNoRole");
                    for (boolean isReply : new boolean[]{false, true}) {
                        replying[0] = isReply;
                        for (String name : new String[]{"Finn", "account_name", ".Bedrock_Friend", "O'Queen", "<click:run_command:'/op me'>Finn</click>"}) {
                            displayName[0] = name;
                            for (String body : new String[]{"hello", "https://example.org/image.png"}) {
                                var result = format.invoke(listener, template, body, event,
                                    hasRole ? List.of(role) : List.of(), hasRole ? role : null, "show", false);
                                String json = GsonComponentSerializer.gson().serialize((github.scarsz.discordsrv.dependencies.kyori.adventure.text.Component) result);
                                // DiscordSRV escapes formatting-like names as
                                // literal text; it does not remove their tags.
                                verify(bridge(json), name.startsWith("<") ? name.replace(">", "\\>") : name,
                                    isReply ? " (replying to Queen)" : "", body, hasRole);
                            }
                        }
                    }
                }
            }
            require(offlineLookups[0] > 0, "Linked offline account was not exercised");
            System.out.println("PASS: actual DiscordSRV name/reply/role/attachment formatting, palette, escaping and Carbon component bridge");
        }
    }
}

import java.lang.reflect.Proxy;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import com.google.gson.JsonParser;
import carbonchat.libs.org.spongepowered.configurate.hocon.HoconConfigurationLoader;
import io.github.miniplaceholders.api.Expansion;
import net.kyori.adventure.audience.Audience;
import net.kyori.adventure.identity.Identity;
import net.kyori.adventure.pointer.Pointers;
import net.kyori.adventure.text.Component;
import net.kyori.adventure.text.format.TextColor;
import net.kyori.adventure.text.minimessage.MiniMessage;
import net.kyori.adventure.text.minimessage.tag.Tag;
import net.kyori.adventure.text.minimessage.tag.resolver.TagResolver;
import net.kyori.adventure.text.serializer.plain.PlainTextComponentSerializer;
import net.luckperms.api.LuckPerms;
import net.luckperms.api.LuckPermsProvider;
import net.luckperms.api.cacheddata.CachedDataManager;
import net.luckperms.api.cacheddata.CachedMetaData;
import net.luckperms.api.context.ContextManager;
import net.luckperms.api.model.user.User;
import net.luckperms.api.model.user.UserManager;
import net.luckperms.api.query.QueryOptions;

// Parse the generated HOCON with Carbon's parser, then exercise the pinned
// LuckPerms expansion with its real MiniMessage tags and a minimal API fixture.
public class ReadCarbon {
    interface Calls { Object call(String method, Object[] args); }
    @SuppressWarnings("unchecked")
    static <T> T stub(Class<T> type, Calls calls) {
        return (T) Proxy.newProxyInstance(type.getClassLoader(), new Class<?>[]{type},
            (proxy, method, args) -> calls.call(method.getName(), args));
    }
    static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    static boolean checkText(Component c, TextColor inherited, String text, TextColor expected) {
        TextColor color = c.color() == null ? inherited : c.color();
        boolean found = c instanceof net.kyori.adventure.text.TextComponent t && t.content().equals(text);
        if (found) require(expected.equals(color), "Wrong color for " + text + ": " + color);
        for (var child : c.children()) found |= checkText(child, color, text, expected);
        return found;
    }
    static boolean hasClick(Component c) {
        return c.clickEvent() != null || c.children().stream().anyMatch(ReadCarbon::hasClick);
    }
    public static void main(String[] args) throws Exception {
        var primary = HoconConfigurationLoader.builder().path(Path.of(args[0])).build().load();
        require(primary.node("config-version").getInt() == 1, "Missing pinned Carbon schema version");
        net.draycia.carbon.common.config.PrimaryConfig.upgrade(primary);
        var channel = HoconConfigurationLoader.builder().path(Path.of(args[1])).build().load();
        require(primary.node("storage-type").getString().equals("JSON"), "Unexpected storage");
        require(primary.node("default-channel").getString().equals("carbon:global"), "Wrong default channel");
        for (String[] path : new String[][]{{"update-checker"}, {"messaging-settings","enabled"},
                {"nickname-settings","use-carbon-nicknames"}, {"nickname-settings","update-tab-list"},
                {"party-chat","enabled"}})
            require(primary.node((Object[]) path).getBoolean() == false, "Enabled competing feature: " + java.util.Arrays.toString(path));
        require(primary.node("integrations","discordsrv","enabled").getBoolean(), "Native bridge disabled");
        require(!primary.node("integrations","miniplaceholders","relational-placeholders").getBoolean(), "Wrong placeholder audience");
        require(channel.node("key").getString().equals("carbon:global"), "Wrong key");
        require(channel.node("command-name").getString().equals("global"), "Discord channel mapping mismatch");
        require(channel.node("radius").getInt() == -1 && !channel.node("cross-server").getBoolean(), "Wrong delivery scope");
        require(channel.node("quick-prefix").getString().isEmpty(), "Quick routing should be disabled");
        String format = channel.node("format","basic","default_format").getString();
        var groups = JsonParser.parseString(Files.readString(Path.of(args[2]))).getAsJsonObject().getAsJsonObject("groups");
        for (var entry : groups.entrySet()) {
            String prefix = "", color = null;
            int priority = -1;
            for (var node : entry.getValue().getAsJsonObject().getAsJsonArray("nodes")) {
                var value = node.getAsJsonObject();
                if (!value.get("value").getAsBoolean()) continue;
                String key = value.get("key").getAsString();
                if (key.startsWith("prefix.")) {
                    String[] parts = key.split("\\.", 3);
                    int p = Integer.parseInt(parts[1]);
                    if (p > priority) { priority = p; prefix = parts[2]; }
                }
                if (key.startsWith("meta.chat_color.")) color = key.substring("meta.chat_color.".length());
            }
            require(color != null, "Missing editable rank color: " + entry.getKey());
            String[] rankPrefix = {prefix};
            String rankColor = color;
            var meta = stub(CachedMetaData.class, (method, a) -> switch(method) {
                case "getPrefix" -> rankPrefix[0];
                case "getMetaValue" -> rankColor;
                default -> null;
            });
            var cached = stub(CachedDataManager.class, (method, a) -> meta);
            var user = stub(User.class, (method, a) -> method.equals("getCachedData") ? cached : null);
            var users = stub(UserManager.class, (method, a) -> user);
            var query = stub(QueryOptions.class, (method, a) -> null);
            var context = stub(ContextManager.class, (method, a) -> Optional.of(query));
            var lp = stub(LuckPerms.class, (method, a) -> switch(method) {
                case "getUserManager" -> users;
                case "getContextManager" -> context;
                default -> null;
            });
            var field = LuckPermsProvider.class.getDeclaredField("instance");field.setAccessible(true);field.set(null, lp);
            var factory = Class.forName("io.github.miniplaceholders.expansion.luckperms.LuckPermsExpansion")
                .getDeclaredMethod("luckPerms");factory.setAccessible(true);
            var expansion = (Expansion) factory.invoke(null);
            UUID id = UUID.randomUUID();
            Audience audience = new Audience() {
                public Pointers pointers() { return Pointers.builder().withStatic(Identity.UUID,id).build(); }
            };
            // Carbon inserts the chat message as a self-closing component. Text
            // that looks like MiniMessage must remain literal, including clicks.
            String body = "<click:run_command:'/op me'><red>hello</red></click>";
            var rendered = MiniMessage.miniMessage().deserialize(format, audience,
                expansion.audiencePlaceholders(),
                TagResolver.resolver("username", Tag.preProcessParsed(".Bedrock_Friend")),
                TagResolver.resolver("message", Tag.selfClosingInserting(Component.text(body))));
            String plain = PlainTextComponentSerializer.plainText().serialize(rendered);
            String expectedPrefix = PlainTextComponentSerializer.plainText().serialize(
                prefix.matches(".*&[0-9a-fk-or].*")
                    ? net.kyori.adventure.text.serializer.legacy.LegacyComponentSerializer.legacyAmpersand().deserialize(prefix)
                    : MiniMessage.miniMessage().deserialize(prefix));
            require(plain.equals(expectedPrefix + ".Bedrock_Friend › " + body), "Unresolved placeholders or unsafe body: " + plain);
            require(!hasClick(rendered), "Player acquired click event");
            TextColor nameColor = MiniMessage.miniMessage().deserialize(color + "name").color();
            require(checkText(rendered, null, ".Bedrock_Friend", nameColor), "Missing name component");
            require(checkText(rendered, null, body, TextColor.fromHexString("#cdd6f4")), "Missing literal body component");
            // Existing PostgreSQL prefixes may still use ampersand formatting
            // before additive rank commands are applied. The expansion handles it.
            rankPrefix[0] = "&d[Mod] ";
            var legacy = MiniMessage.miniMessage().deserialize("<luckperms_prefix>", audience, expansion.audiencePlaceholders());
            require(PlainTextComponentSerializer.plainText().serialize(legacy).equals("[Mod] "), "Legacy prefix rendered literally");
            require(checkText(legacy, null, "[Mod] ", net.kyori.adventure.text.format.NamedTextColor.LIGHT_PURPLE), "Missing legacy prefix");
        }
        System.out.println("PASS: Carbon HOCON and real LuckPerms expansion, every rank, Bedrock username, literal player chat");
    }
}

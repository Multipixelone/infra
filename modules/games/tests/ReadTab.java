import java.io.File;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.OptionalInt;
import java.util.zip.GZIPInputStream;
import java.util.zip.ZipFile;
import com.google.gson.JsonParser;
import me.neznamy.tab.platforms.bukkit.BukkitTabPlayer;
import me.neznamy.tab.shared.TAB;
import me.neznamy.tab.shared.chat.ComponentConfiguration;
import me.neznamy.tab.shared.chat.EnumChatFormat;
import me.neznamy.tab.shared.util.cache.StringToComponentCache;
import me.neznamy.tab.shared.config.Configs;
import me.neznamy.tab.shared.config.files.Config;
import me.neznamy.tab.shared.config.file.YamlConfigurationFile;
import me.neznamy.tab.shared.config.file.YamlPropertyConfigurationFile;
import me.neznamy.tab.shared.features.header.HeaderFooterConfiguration;
import me.neznamy.tab.shared.features.nametags.TeamConfiguration;
import me.neznamy.tab.shared.features.sorting.SortingConfiguration;
import me.neznamy.tab.shared.features.sorting.types.PlaceholderHighToLow;
import me.neznamy.tab.shared.features.sorting.types.SortingType;
import me.neznamy.tab.shared.hook.LuckPermsHook;
import me.neznamy.tab.shared.placeholders.PlaceholderReference;
import me.neznamy.tab.shared.placeholders.PlaceholderReplacementPattern;
import me.neznamy.tab.shared.placeholders.types.ServerPlaceholderImpl;
import me.neznamy.tab.shared.placeholders.types.TabPlaceholder;
import net.kyori.adventure.text.Component;
import net.kyori.adventure.text.TextComponent;
import net.kyori.adventure.text.format.TextColor;
import net.kyori.adventure.text.minimessage.MiniMessage;
import net.kyori.adventure.text.renderer.TranslatableComponentRenderer;
import net.kyori.adventure.text.serializer.gson.GsonComponentSerializer;
import net.kyori.adventure.text.serializer.plain.PlainTextComponentSerializer;
import net.luckperms.api.LuckPerms;
import net.luckperms.api.LuckPermsProvider;
import net.luckperms.api.cacheddata.CachedDataManager;
import net.luckperms.api.cacheddata.CachedMetaData;
import net.luckperms.api.context.ContextManager;
import net.luckperms.api.model.group.Group;
import net.luckperms.api.model.group.GroupManager;
import net.luckperms.api.model.user.User;
import net.luckperms.api.query.QueryOptions;
import sun.misc.Unsafe;

// Isolate TAB's parsers/renderers and LuckPerms API without constructing a
// server, threads or packets. Only initialize the fields these paths read.
public class ReadTab {
    static final Unsafe unsafe;
    static {
        try {
            var f = Unsafe.class.getDeclaredField("theUnsafe"); f.setAccessible(true);
            unsafe = (Unsafe) f.get(null);
        } catch (Exception e) { throw new ExceptionInInitializerError(e); }
    }
    static <T> T empty(Class<T> type) throws Exception { return type.cast(unsafe.allocateInstance(type)); }
    static void set(Class<?> type, Object target, String name, Object value) throws Exception {
        var f = type.getDeclaredField(name); f.setAccessible(true); f.set(target, value);
    }
    static Component render(String text) {
        return StringToComponentCache.GLOBAL.convert(EnumChatFormat.color(text)).toAdventure();
    }
    static String plain(Component component) {
        return PlainTextComponentSerializer.plainText().serialize(component);
    }
    static void colors(Component component, TextColor inherited, List<TextColor> colors) {
        TextColor color = component.color() == null ? inherited : component.color();
        if (component instanceof TextComponent text)
            for (int i = 0; i < text.content().length(); i++) colors.add(color);
        for (var child : component.children()) colors(child, color, colors);
    }
    public static void main(String[] args) throws Exception {
        com.google.gson.JsonObject translations;
        try (var pack = new ZipFile(args[4]); var reader = new InputStreamReader(
                pack.getInputStream(pack.getEntry("assets/infra/lang/en_us.json")), StandardCharsets.UTF_8)) {
            translations = JsonParser.parseReader(reader).getAsJsonObject();
        }
        var javaRenderer = TranslatableComponentRenderer.usingTranslationSource(new net.kyori.adventure.translation.Translator() {
            public net.kyori.adventure.key.Key name() { return net.kyori.adventure.key.Key.key("infra:tab-rank-test"); }
            public java.text.MessageFormat translate(String key, java.util.Locale locale) {
                return translations.has(key) ? new java.text.MessageFormat(translations.get(key).getAsString(), locale) : null;
            }
        });
        var bedrockRenderer = new org.geysermc.geyser.text.MinecraftTranslationRegistry();
        var yaml = new YamlConfigurationFile(null, new File(args[0]));
        var groups = new YamlPropertyConfigurationFile(null, new File(args[1]));
        var components = ComponentConfiguration.fromSection(yaml.getConfigurationSection("components"));
        var config = empty(Config.class); set(Config.class, config, "components", components);
        var configs = empty(Configs.class); set(Configs.class, configs, "config", config);
        var tab = empty(TAB.class); set(TAB.class, tab, "configuration", configs);
        set(TAB.class, null, "instance", tab);
        var header = HeaderFooterConfiguration.fromSection(yaml.getConfigurationSection("header-footer"));
        ReadCarbon.require(header.getDesigns().size() == 1, "Unexpected header design");
        var sorting = SortingConfiguration.fromSection(yaml.getConfigurationSection("scoreboard-teams"));
        TeamConfiguration.fromSection(yaml.getConfigurationSection("scoreboard-teams"));
        ReadCarbon.require(sorting.getSortingTypes().getFirst().equals("PLACEHOLDER_HIGH_TO_LOW:%luckperms-weight%"), "Wrong native weight placeholder");
        ReadCarbon.require(!sorting.isCaseSensitiveSorting(), "Alphabetical tie-breaking must ignore case");
        var design = yaml.getConfigurationSection("header-footer").getConfigurationSection("designs").getConfigurationSection("default");
        for (String location : List.of("header", "footer")) {
            for (String line : design.getStringList(location)) {
                String resolved = line.replace("%online%", "3").replace("%ping%", "42").replace("%tps%", "20").replace("%mspt%", "7.5");
                var rendered = render(resolved);
                ReadCarbon.require(!plain(rendered).contains("<") && !plain(rendered).contains("%"), "Unparsed TAB text: " + plain(rendered));
                if (plain(rendered).equals("Finn's Survival")) {
                    var colors = new ArrayList<TextColor>(); colors(rendered, null, colors);
                    ReadCarbon.require(colors.getFirst().equals(TextColor.fromHexString("#cba6f7")), "Missing mauve gradient endpoint");
                    ReadCarbon.require(colors.getLast().equals(TextColor.fromHexString("#fab387")), "Missing peach gradient endpoint");
                    ReadCarbon.require(colors.stream().distinct().count() > 3, "Gradient collapsed");
                }
            }
        }
        var bootstrap = JsonParser.parseReader(new InputStreamReader(new GZIPInputStream(Files.newInputStream(Path.of(args[2]))), StandardCharsets.UTF_8)).getAsJsonObject();
        var keys = new ArrayList<Map.Entry<String, String>>();
        var numeric = empty(PlaceholderHighToLow.class);
        var value = empty(ServerPlaceholderImpl.class);
        set(TabPlaceholder.class, value, "replacements", PlaceholderReplacementPattern.EMPTY);
        set(SortingType.class, numeric, "sortingPlaceholder", new PlaceholderReference("%luckperms-weight%", value));
        for (var entry : bootstrap.getAsJsonObject("groups").entrySet()) {
            String rank = entry.getKey(), color = null, prefix = "";
            int weight = 0;
            for (var node : entry.getValue().getAsJsonObject().getAsJsonArray("nodes")) {
                String key = node.getAsJsonObject().get("key").getAsString();
                if (key.startsWith("meta.chat_color.")) color = key.substring("meta.chat_color.".length());
                if (key.startsWith("prefix.")) prefix = key.split("\\.", 3)[2];
                if (key.startsWith("weight.")) weight = Integer.parseInt(key.substring("weight.".length()));
            }
            final int groupWeight = weight;
            final String[] livePrefix = {prefix};
            var meta = ReadCarbon.stub(CachedMetaData.class, (method, a) -> livePrefix[0]);
            var cached = ReadCarbon.stub(CachedDataManager.class, (method, a) -> meta);
            var user = ReadCarbon.stub(User.class, (method, a) -> method.equals("getPrimaryGroup") ? rank : cached);
            var group = ReadCarbon.stub(Group.class, (method, a) -> OptionalInt.of(groupWeight));
            var manager = ReadCarbon.stub(GroupManager.class, (method, a) -> group);
            var query = ReadCarbon.stub(QueryOptions.class, (method, a) -> null);
            var context = ReadCarbon.stub(ContextManager.class, (method, a) -> Optional.of(query));
            var lp = ReadCarbon.stub(LuckPerms.class, (method, a) -> method.equals("getGroupManager") ? manager : context);
            set(LuckPermsProvider.class, null, "instance", lp);
            var player = empty(BukkitTabPlayer.class); player.luckPermsUser = user;
            var hook = LuckPermsHook.getInstance();
            ReadCarbon.require(hook.getWeight(player) == weight, "LuckPerms weight hook mismatch");
            set(ServerPlaceholderImpl.class, value, "lastReturnedValue", Integer.toString(hook.getWeight(player)));
            keys.add(Map.entry(rank, numeric.getChars(player)));
            String name = ".Bedrock_Friend";
            String format = groups.getProperty(rank, "customtabname", null, null)[0].replace("%displayname%", name);
            TextColor expected = MiniMessage.miniMessage().deserialize(color + "name").color();
            ReadCarbon.require(hook.getPrefix(player).equals(prefix), "LuckPerms hook changed the prefix");
            // Exercise the real MiniMessage -> TAB component -> Adventure path,
            // then the JSON transport. Flattening the prefix loses the fallback.
            var serializer = GsonComponentSerializer.gson();
            var transported = serializer.deserialize(serializer.serialize(render(hook.getPrefix(player) + format)));
            String rankKey = "infra.rank." + rank;
            String label = rank.substring(0, 1).toUpperCase() + rank.substring(1);
            String javaText = plain(javaRenderer.render(transported, java.util.Locale.US));
            String bedrockText = plain(bedrockRenderer.render(transported, "en_us"));
            if (!rank.equals("default")) {
                ReadCarbon.require(ReadCarbon.hasRank(transported, rankKey, "[" + label + "]", label), "TAB lost the translatable rank prefix");
                ReadCarbon.require(javaText.equals(translations.get(rankKey).getAsString() + " " + name), "TAB Java icon did not resolve");
                ReadCarbon.require(bedrockText.equals("[" + label + "] " + name), "TAB Bedrock rank fallback failed");
            } else {
                ReadCarbon.require(javaText.equals(name) && javaText.equals(bedrockText), "TAB default player gained a badge");
            }
            ReadCarbon.require(bedrockText.codePoints().noneMatch(cp -> cp >= 0xe000 && cp <= 0xf8ff), "TAB PUA leaked to Bedrock");
            ReadCarbon.require(ReadCarbon.checkText(transported, null, name, expected), "TAB transport lost rank name color");
            // A coloured Bukkit display name overrides the rank colour; the
            // reset after it keeps the rest of TAB's presentation independent.
            String nickname = "§x§5§5§a§a§f§fFinn";
            String nickFormat = groups.getProperty(rank, "customtabname", null, null)[0]
                .replace("%displayname%", nickname);
            var nickRendered = render(hook.getPrefix(player) + nickFormat);
            ReadCarbon.require(plain(nickRendered).endsWith("Finn"), "TAB did not render the nickname");
            ReadCarbon.require(ReadCarbon.checkText(nickRendered, null, "Finn", TextColor.fromHexString("#55aaff")), "TAB lost nickname colour");
            for (String testPrefix : new String[]{prefix, "&d◆&r ", "<green>★</green> "}) {
                livePrefix[0] = testPrefix;
                var rendered = render(hook.getPrefix(player) + format);
                ReadCarbon.require(plain(rendered).endsWith(name), "Unparsed prefix/name: " + plain(rendered));
                ReadCarbon.require(ReadCarbon.checkText(rendered, null, name, expected), "Rank color lost after prefix reset");
                if (testPrefix.contains("◆") || testPrefix.contains("★"))
                    ReadCarbon.require(plain(rendered).startsWith(testPrefix.contains("◆") ? "◆ " : "★ "), "Live rank icon missing");
            }
        }
        keys.sort(Comparator.comparing(Map.Entry::getValue));
        ReadCarbon.require(keys.stream().map(Map.Entry::getKey).toList().equals(List.of("admin", "mod", "builder", "default")), "Wrong weight order: " + keys);
        var events = new YamlConfigurationFile(null, new File(args[3]));
        String welcome = events.getConfigurationSection("message").getConfigurationSection("join").getString("format_first_time").replace("<player>", "Friend");
        ReadCarbon.require(!plain(render(welcome)).contains("<"), "Welcome invite did not render");
        System.out.println("PASS: TAB YAML/MiniMessage, gradient, native LuckPerms weight order, rank translation/fallback round-trip and live prefixes");
    }
}

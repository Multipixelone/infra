import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Proxy;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import net.william278.huskhomes.HuskHomes;
import net.william278.huskhomes.config.ConfigProvider;
import net.william278.huskhomes.config.Locales;
import net.william278.huskhomes.config.Settings;
import net.william278.huskhomes.database.SqLiteDatabase;
import net.william278.huskhomes.hook.BlueMapHook;
import net.william278.huskhomes.libraries.configlib.YamlConfigurations;
import net.william278.huskhomes.manager.HomesManager;
import net.william278.huskhomes.position.Home;
import net.william278.huskhomes.position.Position;
import net.william278.huskhomes.position.PositionMeta;
import net.william278.huskhomes.position.Warp;
import net.william278.huskhomes.position.World;
import net.william278.huskhomes.user.User;

// Run the real hook and home cache against BlueMap 5.28; no Minecraft process.
public class CheckHuskMap {
    public static void main(String[] args) throws Exception {
        Settings settings = YamlConfigurations.load(Path.of(args[0]), Settings.class,
            ConfigProvider.YAML_CONFIGURATION_PROPERTIES.build());
        var localesConstructor = Locales.class.getDeclaredConstructor();
        localesConstructor.setAccessible(true);
        Locales locales = localesConstructor.newInstance();
        World world = World.from("world", UUID.randomUUID());
        Position position = Position.at(12, 64, 34, world, "survival");
        User owner = User.of(UUID.randomUUID(), "owner");
        Home privateHome = Home.from(position, PositionMeta.create("private", ""), owner);
        Home publicHome = Home.from(position, PositionMeta.create("public", ""), owner);
        publicHome.setPublic(true);
        Warp warp = Warp.from(position, PositionMeta.create("spawn", ""));
        var homes = List.of(privateHome, publicHome);
        var hooks = new ArrayList<BlueMapHook>();
        SqLiteDatabase[] database = {null};
        int[] publicQueries = {0};
        HuskHomes plugin = (HuskHomes) Proxy.newProxyInstance(HuskHomes.class.getClassLoader(),
            new Class<?>[]{HuskHomes.class}, (proxy, method, arguments) -> switch (method.getName()) {
                case "getSettings" -> settings;
                case "getServerName" -> "survival";
                case "getConfigDirectory" -> Path.of(".");
                case "getDatabase" -> database[0];
                case "getWorlds" -> List.of(world);
                case "getLocales" -> locales;
                case "getHooks" -> Set.copyOf(hooks);
                case "getCommands" -> List.of();
                case "getResource" -> HuskHomes.class.getClassLoader().getResourceAsStream((String) arguments[0]);
                // Constructor's background cache refresh isn't needed here.
                case "runAsync" -> null;
                default -> {
                    if (method.isDefault()) yield InvocationHandler.invokeDefault(proxy, method, arguments);
                    throw new AssertionError("Unexpected HuskHomes call: " + method);
                }
            });
        database[0] = new SqLiteDatabase(plugin) {
            public List<Home> getPublicHomes() {
                publicQueries[0]++;
                return homes.stream().filter(Home::isPublic).toList();
            }
            public List<Warp> getWarps() { return List.of(warp); }
        };
        BlueMapFixture api = new BlueMapFixture(Path.of("web"));
        BlueMapHook hook = new BlueMapHook(plugin);
        hooks.add(hook);
        // Register first, then load: BlueMapAPI invokes the real listener now.
        api.start();
        hook.load();
        if (publicQueries[0] == 0) throw new AssertionError("startup bypassed public-home query");
        var homeSet = api.markerSets.values().stream()
            .filter(set -> set.getLabel().equals("Public Homes")).findFirst().orElseThrow();
        var warpSet = api.markerSets.values().stream()
            .filter(set -> set.getLabel().equals("Warps")).findFirst().orElseThrow();
        if (homeSet.getMarkers().size() != 1 || warpSet.getMarkers().size() != 1)
            throw new AssertionError("startup public homes/warps missing or private home leaked");
        if (homeSet.isDefaultHidden() || !homeSet.isToggleable() || warpSet.isDefaultHidden() || !warpSet.isToggleable())
            throw new AssertionError("public marker set visibility changed");
        var constructor = HomesManager.class.getDeclaredConstructor(HuskHomes.class);
        constructor.setAccessible(true);
        HomesManager manager = constructor.newInstance(plugin);
        manager.cacheHome(privateHome, false);
        if (homeSet.getMarkers().size() != 1) throw new AssertionError("private home leaked on cache update");
        publicHome.setPublic(false);
        manager.cacheHome(publicHome, false);
        if (!homeSet.getMarkers().isEmpty()) throw new AssertionError("privatized home remains public");
        publicHome.setPublic(true);
        manager.cacheHome(publicHome, false);
        if (homeSet.getMarkers().size() != 1) throw new AssertionError("published home missing");
        manager.unCacheHome(publicHome.getUuid(), false);
        if (!homeSet.getMarkers().isEmpty()) throw new AssertionError("deleted home remains public");
        hook.unload();
        api.stop();
        System.out.println("PASS: HuskHomes hook, visible public homes/warps, private transitions and deletion");
    }
}

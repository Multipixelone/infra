import java.nio.file.Path;
import net.william278.huskhomes.config.ConfigProvider;
import net.william278.huskhomes.config.Settings;
import net.william278.huskhomes.libraries.configlib.YamlConfigurations;

public class ReadHuskSettings {
    public static void main(String[] args) throws Exception {
        Settings s = YamlConfigurations.load(Path.of(args[0]), Settings.class,
            ConfigProvider.YAML_CONFIGURATION_PROPERTIES.build());
        if (s.isCheckForUpdates()) throw new AssertionError("update checks enabled");
        if (!s.getDatabase().getType().toString().equals("SQLITE")) throw new AssertionError("wrong DB");
        if (s.getCrossServer().isEnabled()) throw new AssertionError("cross-server enabled");
        if (!s.getMapHook().isEnabled() || !s.getMapHook().isShowPublicHomes() || !s.getMapHook().isShowWarps())
            throw new AssertionError("map hook disabled");
        if (s.getGeneral().getMaxHomes() != 10) throw new AssertionError("home limit wrong");
        if (s.getGeneral().isStackPermissionLimits()) throw new AssertionError("limits stack");
        if (!s.getGeneral().getHomeDelimiter().equals(":")) throw new AssertionError("Bedrock delimiter wrong");
        if (s.getEconomy().isEnabled()) throw new AssertionError("economy enabled");
        if (!s.getLuckperms().isEnabled()) throw new AssertionError("permission hook disabled");
        System.out.println("PASS: upstream Settings parser, SQLite, no cross-server/updates, BlueMap, 10 homes");
    }
}

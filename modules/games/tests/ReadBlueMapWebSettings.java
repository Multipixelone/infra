import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashSet;
import java.util.List;
import de.bluecolored.bluemap.common.WebFilesManager;
import de.bluecolored.bluemap.common.config.ConfigManager;
import de.bluecolored.bluemap.common.config.WebappConfig;
import de.bluecolored.bluemap.common.config.PluginConfig;
import de.bluecolored.bluemap.common.config.CoreConfig;

/** Exercise the pinned plugin's parser, settings writer and webroot updater. */
public class ReadBlueMapWebSettings {
    public static void main(String[] args) throws Exception {
        Path configuration = Path.of(args[0]);
        ConfigManager manager = new ConfigManager(configuration.getParent());
        PluginConfig plugin = manager.loadConfig(Path.of(args[3]), PluginConfig.class);
        CoreConfig core = manager.loadConfig(Path.of(args[4]), CoreConfig.class);
        if (plugin.getPlayerRenderLimit() != -1)
            throw new AssertionError("online players must not pause rendering");
        if (core.resolveRenderThreadCount() != 1 || core.getRenderThreadPriority() != 1)
            throw new AssertionError("render resource budget changed");
        if (!core.getUpdateCooldown().equals(java.time.Duration.ofSeconds(60))
                || !core.getFullUpdateInterval().equals(java.time.Duration.ofDays(1)))
            throw new AssertionError("render update timing changed");
        WebappConfig config = new ConfigManager(configuration.getParent())
            .loadConfig(configuration, WebappConfig.class);
        if (!config.getStyles().equals(new LinkedHashSet<>(List.of("css/homepage-theme.css"))))
            throw new AssertionError("custom stylesheet registration changed");
        if (!config.getScripts().isEmpty()) throw new AssertionError("unexpected scripts");
        if (!config.isEnabled() || !config.isClientDecompression())
            throw new AssertionError("static webapp disabled");
        if (!config.getWebroot().equals(Path.of(args[2])))
            throw new AssertionError("wrong webroot");
        Path fixture = Path.of(args[1]);
        WebFilesManager web = new WebFilesManager(fixture);
        web.setFrom(config);
        web.saveSettings();
        Path style = fixture.resolve("css/homepage-theme.css");
        byte[] before = Files.readAllBytes(style);
        // Real startup/update extraction must preserve the managed custom file.
        web.updateFiles();
        web.updateFiles();
        if (!java.util.Arrays.equals(before, Files.readAllBytes(style)))
            throw new AssertionError("webapp update overwrote the custom stylesheet");
        System.out.println("PASS: BlueMap HOCON, settings.json and repeat webroot updates");
    }
}

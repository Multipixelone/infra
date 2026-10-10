import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashSet;
import java.util.List;
import de.bluecolored.bluemap.common.WebFilesManager;
import de.bluecolored.bluemap.common.config.ConfigManager;
import de.bluecolored.bluemap.common.config.WebappConfig;

/** Exercise the pinned plugin's parser, settings writer and webroot updater. */
public class ReadBlueMapWebSettings {
    public static void main(String[] args) throws Exception {
        Path configuration = Path.of(args[0]);
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

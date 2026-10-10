import com.technicjelle.bluemapfloodgate.BlueMapFloodgate;
import com.technicjelle.bluemapfloodgate.shadow.UpdateChecker;
import com.technicjelle.bluemapfloodgate.shadow.BMUtils.BMNative.BMNLogger;
import java.awt.image.BufferedImage;
import java.io.*;
import java.lang.reflect.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import javax.imageio.ImageIO;

/** Exercise the pinned plugin's actual provider with local responses; never contact skin services. */
public final class CheckFloodgate {
  public static void main(String[] args) throws Exception {
    System.setProperty("technicjelle.updatechecker.disabled", "true");
    BufferedImage bedrockSkin = new BufferedImage(64, 64, BufferedImage.TYPE_INT_ARGB);
    bedrockSkin.setRGB(8, 8, 0xff35a954);
    ByteArrayOutputStream png = new ByteArrayOutputStream();
    ImageIO.write(bedrockSkin, "png", png);
    List<String> requests = new ArrayList<>();
    URL.setURLStreamHandlerFactory(protocol -> {
      if (!protocol.equals("https") && !protocol.equals("http")) return null;
      return new URLStreamHandler() {
        protected URLConnection openConnection(URL url) {
          requests.add(url.toString());
          byte[] payload;
          if (url.getHost().equals("api.geysermc.org") && url.getPath().endsWith("/12345")) {
            payload = "{\"texture_id\":\"fixture-texture\"}".getBytes(StandardCharsets.UTF_8);
          } else if (url.getHost().equals("textures.minecraft.net") && url.getPath().endsWith("fixture-texture")) {
            payload = png.toByteArray();
          } else if (url.getHost().equals("api.geysermc.org") && url.getPath().endsWith("/54321")) {
            payload = "{}".getBytes(StandardCharsets.UTF_8);
          } else throw new AssertionError("Unexpected outbound request: " + url);
          return new URLConnection(url) {
            public void connect() { }
            public InputStream getInputStream() { return new ByteArrayInputStream(payload); }
            public Object getContent() { return getInputStream(); }
          };
        }
      };
    });
    BlueMapFixture fixture = new BlueMapFixture(Path.of("floodgate-fixture/web"));
    BufferedImage javaSkin = new BufferedImage(64, 64, BufferedImage.TYPE_INT_ARGB);
    List<UUID> fallbackPlayers = new ArrayList<>();
    fixture.plugin.skinProvider = uuid -> { fallbackPlayers.add(uuid); return Optional.of(javaSkin); };
    BlueMapFloodgate plugin = BlueMapFixture.allocate(BlueMapFloodgate.class);
    BlueMapFixture.setField(plugin, "logger", new BMNLogger("BlueMapFloodgate"));
    BlueMapFixture.setField(plugin, "updateChecker", new UpdateChecker("TechnicJelle", "BlueMapFloodgate", "3.6"));
    // The instance cannot run JavaPlugin's server constructor; invoke its compiled BlueMap-enable callback.
    Method callback = BlueMapFloodgate.class.getDeclaredMethod("lambda$new$0", de.bluecolored.bluemap.api.BlueMapAPI.class);
    callback.setAccessible(true);
    callback.invoke(plugin, fixture);
    UUID bedrock = new UUID(0, 12345);
    BufferedImage loaded = fixture.plugin.skinProvider.load(bedrock).orElseThrow();
    BlueMapFixture.require(loaded.getRGB(8, 8) == bedrockSkin.getRGB(8, 8), "Bedrock skin pixels were not loaded");
    BlueMapFixture.require(requests.size() == 2 && fallbackPlayers.isEmpty(), "Bedrock player did not route to Geyser texture service");
    UUID javaPlayer = UUID.fromString("a394fe5a-53ae-4c9b-9e19-5ca78f2b7358");
    BlueMapFixture.require(fixture.plugin.skinProvider.load(javaPlayer).orElseThrow() == javaSkin, "Java player's provider changed");
    BlueMapFixture.require(fallbackPlayers.equals(List.of(javaPlayer)) && requests.size() == 2, "Java player requested a Bedrock skin");
    BlueMapFixture.require(fixture.plugin.skinProvider.load(new UUID(0, 54321)).isEmpty(), "Missing Bedrock skin should produce empty provider result");
    System.out.println("Floodgate release provider: Bedrock texture pixels, Java fallback, missing texture verified");
  }
}

import de.bluecolored.bluemap.api.*;
import de.bluecolored.bluemap.api.markers.MarkerSet;
import de.bluecolored.bluemap.api.plugin.*;
import java.awt.image.BufferedImage;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import javax.imageio.ImageIO;

/** Small API fixture: the addon bytecode and marker builders remain the real release code. */
public final class BlueMapFixture extends BlueMapAPI {
  public final Map<String, MarkerSet> markerSets = new LinkedHashMap<>();
  public final Set<String> styles = new LinkedHashSet<>();
  public final Set<String> scripts = new LinkedHashSet<>();
  public final Set<UUID> hiddenPlayers = new HashSet<>();
  public BlueMapMap map;
  public BlueMapWorld world;
  public final WebApp webApp;
  public final FixturePlugin plugin = new FixturePlugin();

  public BlueMapFixture(Path webroot) throws Exception {
    Files.createDirectories(webroot);
    world = proxy(BlueMapWorld.class, (p, m, a) -> switch (m.getName()) {
      case "getId" -> "world";
      case "getSaveFolder" -> webroot.getParent().resolve("world");
      case "getMaps" -> List.of(map);
      default -> unsupported(m);
    });
    map = proxy(BlueMapMap.class, (p, m, a) -> switch (m.getName()) {
      case "getId", "getName" -> "world";
      case "getWorld" -> world;
      case "getMarkerSets" -> markerSets;
      case "getAssetStorage" -> proxy(AssetStorage.class, (ap, am, aa) -> switch (am.getName()) {
        case "assetExists" -> Files.exists(webroot.resolve("assets").resolve((String) aa[0]));
        case "getAssetUrl" -> "assets/" + aa[0];
        case "writeAsset" -> {
          Path target = webroot.resolve("assets").resolve((String) aa[0]);
          Files.createDirectories(target.getParent());
          yield Files.newOutputStream(target);
        }
        default -> unsupported(am);
      });
      default -> unsupported(m);
    });
    webApp = new WebApp() {
      public Path getWebRoot() { return webroot; }
      public void setPlayerVisibility(UUID id, boolean visible) {
        if (visible) hiddenPlayers.remove(id); else hiddenPlayers.add(id);
      }
      public boolean getPlayerVisibility(UUID id) { return !hiddenPlayers.contains(id); }
      public void registerStyle(String style) { styles.add(style); }
      public void registerScript(String script) { scripts.add(script); }
      public String createImage(BufferedImage image, String name) throws java.io.IOException {
        Path target = webroot.resolve("assets").resolve(name + ".png");
        Files.createDirectories(target.getParent());
        ImageIO.write(image, "png", target.toFile());
        return "assets/" + name + ".png";
      }
      public Map<String, String> availableImages() { return Map.of(); }
    };
  }
  public RenderManager getRenderManager() { throw new UnsupportedOperationException(); }
  public WebApp getWebApp() { return webApp; }
  public FixturePlugin getPlugin() { return plugin; }
  public Collection<BlueMapMap> getMaps() { return List.of(map); }
  public Collection<BlueMapWorld> getWorlds() { return List.of(world); }
  public Optional<BlueMapWorld> getWorld(Object ignored) { return Optional.of(world); }
  public Optional<BlueMapMap> getMap(String id) { return Optional.of(map); }
  public String getBlueMapVersion() { return "5.28"; }
  public void start() throws Exception { registerInstance(this); }
  public void stop() throws Exception { unregisterInstance(this); }

  public static final class FixturePlugin implements Plugin {
    public SkinProvider skinProvider = id -> Optional.empty();
    private PlayerIconFactory iconFactory;
    private PlayerDisplayNameProvider nameProvider;
    public SkinProvider getSkinProvider() { return skinProvider; }
    public void setSkinProvider(SkinProvider provider) { skinProvider = provider; }
    public PlayerIconFactory getPlayerMarkerIconFactory() { return iconFactory; }
    public void setPlayerMarkerIconFactory(PlayerIconFactory factory) { iconFactory = factory; }
    public PlayerDisplayNameProvider getPlayerDisplayNameProvider() { return nameProvider; }
    public void setPlayerDisplayNameProvider(PlayerDisplayNameProvider provider) { nameProvider = provider; }
  }
  public static Object unsupported(Method method) {
    throw new AssertionError("Unexpected fixture call: " + method);
  }
  public static <T> T proxy(Class<T> type, InvocationHandler handler) {
    return type.cast(Proxy.newProxyInstance(type.getClassLoader(), new Class<?>[]{type}, handler));
  }
  /** Avoid JavaPlugin's server-only constructor; no addon production code is modified. */
  public static <T> T allocate(Class<T> type) throws Exception {
    Field field = sun.misc.Unsafe.class.getDeclaredField("theUnsafe");
    field.setAccessible(true);
    return type.cast(((sun.misc.Unsafe) field.get(null)).allocateInstance(type));
  }
  public static void setField(Object target, String name, Object value) throws Exception {
    for (Class<?> type = target.getClass(); type != null; type = type.getSuperclass()) {
      try {
        Field field = type.getDeclaredField(name);
        field.setAccessible(true);
        field.set(target, value);
        return;
      } catch (NoSuchFieldException ignored) { }
    }
    throw new NoSuchFieldException(name);
  }
  public static void require(boolean condition, String message) {
    if (!condition) throw new AssertionError(message);
  }
}

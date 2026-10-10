import com.technicjelle.bluemapofflineplayermarkers.common.*;
import com.technicjelle.bluemapofflineplayermarkers.core.*;
import com.technicjelle.bluemapofflineplayermarkers.core.fileloader.FileMarkerLoader;
import com.technicjelle.bluemapofflineplayermarkers.core.markerhandler.BlueMapMarkerHandler;
import com.technicjelle.bluemapofflineplayermarkers.impl.paper.*;
import com.technicjelle.bluemapofflineplayermarkers.shadow.BMUtils.BMCopy;
import de.bluecolored.bluemap.api.markers.*;
import org.bukkit.Bukkit;
import org.bukkit.World;
import org.bukkit.OfflinePlayer;
import org.bukkit.configuration.file.YamlConfiguration;
import org.bukkit.plugin.java.JavaPlugin;
import java.io.*;
import java.lang.reflect.*;
import java.net.URL;
import java.nio.file.*;
import java.util.*;
import java.util.zip.GZIPOutputStream;

public final class CheckOfflineMarkers {
  static class FixturePlugin extends JavaPlugin { }

  public static void main(String[] args) throws Exception {
    // Fail any unexpected network use rather than let a fixture consult real services.
    URL.setURLStreamHandlerFactory(protocol -> {
      if (!protocol.equals("https") && !protocol.equals("http")) return null;
      return new java.net.URLStreamHandler() {
        protected java.net.URLConnection openConnection(URL url) { throw new AssertionError("Unexpected outbound request: " + url); }
      };
    });
    Path root = Path.of("offline-fixture");
    Path worldRoot = root.resolve("world");
    Path playerData = worldRoot.resolve("players/data");
    Files.createDirectories(playerData);
    BlueMapFixture fixture = new BlueMapFixture(root.resolve("web"));
    Set<UUID> online = new HashSet<>(), banned = new HashSet<>();
    UUID worldID = UUID.fromString("d42b51e6-caa6-4f6a-bd0e-df0aecf7550f");
    World world = BlueMapFixture.proxy(World.class, (p, m, a) -> switch (m.getName()) {
      case "getWorldFolder" -> worldRoot.resolve("dimensions/minecraft/overworld").toFile();
      case "getUID" -> worldID;
      case "getEnvironment" -> World.Environment.NORMAL;
      default -> BlueMapFixture.unsupported(m);
    });
    org.bukkit.Server bukkit = BlueMapFixture.proxy(org.bukkit.Server.class, (p, m, a) -> switch (m.getName()) {
      case "getWorlds" -> List.of(world);
      case "getWorld" -> world;
      case "getOfflinePlayer" -> {
        UUID id = (UUID) a[0];
        yield BlueMapFixture.proxy(OfflinePlayer.class, (op, om, oa) -> switch (om.getName()) {
          case "getName" -> "fixture-" + id.toString().substring(0, 8);
          case "getLastSeen" -> 1L; // Old players must survive the requested zero expiry.
          case "isOnline" -> online.contains(id);
          case "isBanned" -> banned.contains(id);
          default -> BlueMapFixture.unsupported(om);
        });
      }
      default -> BlueMapFixture.unsupported(m);
    });
    Field bukkitField = Bukkit.class.getDeclaredField("server");
    bukkitField.setAccessible(true);
    bukkitField.set(null, bukkit);
    FixturePlugin plugin = BlueMapFixture.allocate(FixturePlugin.class);
    BlueMapFixture.setField(plugin, "server", bukkit);
    BlueMapFixture.setField(plugin, "classLoader", BlueMapOfflinePlayerMarkers.class.getClassLoader());
    BlueMapFixture.setField(plugin, "dataFolder", root.resolve("plugin").toFile());
    YamlConfiguration yaml = new YamlConfiguration();
    yaml.load(Path.of(args[0]).toFile());
    BlueMapFixture.setField(plugin, "newConfig", yaml);
    // PaperConfig reloads on construction; override its config file to the exact generated template.
    BlueMapFixture.setField(plugin, "configFile", Path.of(args[0]).toFile());
    PaperConfig config = new PaperConfig(plugin);
    BlueMapFixture.require(config.getMarkerSetName().equals("Offline Players") && config.isToggleable()
        && !config.isDefaultHidden() && config.getExpireTimeInHours() == 0 && config.hideBannedPlayers()
        && config.isGameModeHidden(GameMode.SPECTATOR), "Generated config not understood by upstream PaperConfig");
    PaperServer server = new PaperServer(plugin);
    BlueMapFixture.require(server.getPlayerDataFolder().equals(playerData), "Paper 26.3 players/data layout was not selected");
    BlueMapMarkerHandler handler = new BlueMapMarkerHandler();
    com.technicjelle.bluemapofflineplayermarkers.common.Logger logger = BlueMapFixture.proxy(
        com.technicjelle.bluemapofflineplayermarkers.common.Logger.class, (p, m, a) -> {
          if (m.getName().equals("error")) throw new AssertionError("Upstream loader error: " + a[0], a.length > 1 ? (Throwable) a[1] : null);
          return null;
        });
    Singletons.init(server, logger, config, handler);
    UUID offlineID = UUID.fromString("b394fe5a-53ae-4c9b-9e19-5ca78f2b7358");
    UUID onlineID = UUID.fromString("c394fe5a-53ae-4c9b-9e19-5ca78f2b7358");
    UUID bannedID = UUID.fromString("d394fe5a-53ae-4c9b-9e19-5ca78f2b7358");
    UUID spectatorID = UUID.fromString("e394fe5a-53ae-4c9b-9e19-5ca78f2b7358");
    UUID hiddenID = UUID.fromString("f394fe5a-53ae-4c9b-9e19-5ca78f2b7358");
    online.add(onlineID); banned.add(bannedID); fixture.hiddenPlayers.add(hiddenID);
    for (UUID id : List.of(offlineID, onlineID, bannedID, spectatorID, hiddenID)) {
      writePlayerData(playerData.resolve(id + ".dat"), worldID, id.equals(spectatorID) ? 3 : 0);
    }
    // 26.1 migrations can leave this invalid file; 3.3 must skip it.
    writePlayerData(playerData.resolve("00000000-0000-0000-0000-000000000000.dat"), worldID, 0);
    FileMarkerLoader.loadOfflineMarkers(fixture);
    MarkerSet markers = fixture.markerSets.get("offline-players");
    BlueMapFixture.require(markers != null && markers.getMarkers().keySet().equals(Set.of(offlineID.toString())), "Startup markers leaked online, banned, spectator or hidden players");
    BlueMapFixture.require(!markers.isDefaultHidden() && markers.isToggleable(), "Logout layer is not visible and toggleable");
    POIMarker marker = (POIMarker) markers.getMarkers().get(offlineID.toString());
    BlueMapFixture.require(marker.getPosition().getX() == 12.0 && marker.getPosition().getZ() == -4.0, "Startup logout coordinates differ from NBT");
    fixture.start();
    org.bukkit.entity.Player joined = BlueMapFixture.proxy(org.bukkit.entity.Player.class, (p, m, a) -> switch (m.getName()) {
      case "getUniqueId" -> offlineID;
      case "getName" -> "fixture-player";
      case "getGameMode" -> org.bukkit.GameMode.SURVIVAL;
      case "getLocation" -> new org.bukkit.Location(world, 12, 64, -4);
      case "getWorld" -> world;
      default -> BlueMapFixture.unsupported(m);
    });
    Method join = BlueMapOfflinePlayerMarkers.class.getDeclaredMethod("lambda$onJoin$0", org.bukkit.event.player.PlayerJoinEvent.class);
    join.setAccessible(true);
    join.invoke(null, new org.bukkit.event.player.PlayerJoinEvent(joined, (String) null));
    BlueMapFixture.require(markers.getMarkers().isEmpty(), "Rejoining player kept logout marker");
    Method leave = BlueMapOfflinePlayerMarkers.class.getDeclaredMethod("lambda$onLeave$0", org.bukkit.event.player.PlayerQuitEvent.class);
    leave.setAccessible(true);
    leave.invoke(null, new org.bukkit.event.player.PlayerQuitEvent(joined, (String) null));
    BlueMapFixture.require(markers.getMarkers().keySet().equals(Set.of(offlineID.toString())), "Logout callback did not add marker");
    fixture.stop();
    fixture.styles.add("assets/fixture-theme.css");
    ClassLoader loader = BlueMapOfflinePlayerMarkers.class.getClassLoader();
    BMCopy.jarResourceToWebApp(fixture, loader, "style.css", "bmopm.css", false);
    BMCopy.jarResourceToWebApp(fixture, loader, "script.js", "bmopm.js", false);
    BlueMapFixture.require(fixture.styles.equals(Set.of("assets/fixture-theme.css", "assets/bmopm.css")) && fixture.scripts.equals(Set.of("assets/bmopm.js")), "Addon registration overwrote existing theme");
    BlueMapFixture.require(Files.size(root.resolve("web/assets/bmopm.css")) > 0 && Files.size(root.resolve("web/assets/bmopm.js")) > 0, "Offline web assets were not persisted");
    Singletons.cleanup();
    System.out.println("Offline release: Paper 26.3 NBT startup, no expiry, visible layer, logout/rejoin, privacy exclusions and persistent web assets verified");
  }

  static void writePlayerData(Path target, UUID world, int gameMode) throws IOException {
    try (DataOutputStream out = new DataOutputStream(new GZIPOutputStream(Files.newOutputStream(target)))) {
      out.writeByte(10); out.writeUTF("");
      out.writeByte(3); out.writeUTF("playerGameType"); out.writeInt(gameMode);
      out.writeByte(9); out.writeUTF("Pos"); out.writeByte(6); out.writeInt(3);
      out.writeDouble(12); out.writeDouble(64); out.writeDouble(-4);
      out.writeByte(4); out.writeUTF("WorldUUIDMost"); out.writeLong(world.getMostSignificantBits());
      out.writeByte(4); out.writeUTF("WorldUUIDLeast"); out.writeLong(world.getLeastSignificantBits());
      out.writeByte(8); out.writeUTF("Dimension"); out.writeUTF("minecraft:overworld");
      out.writeByte(0);
    }
  }
}

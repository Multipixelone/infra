import com.flowpowered.math.vector.Vector3d;
import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import de.bluecolored.bluemap.api.markers.MarkerSet;
import de.bluecolored.bluemap.api.markers.POIMarker;
import de.bluecolored.bluemap.common.BlueMapConfiguration;
import de.bluecolored.bluemap.common.BlueMapService;
import de.bluecolored.bluemap.common.config.ConfigManager;
import de.bluecolored.bluemap.common.config.PluginConfig;
import de.bluecolored.bluemap.common.config.WebserverConfig;
import de.bluecolored.bluemap.common.live.PluginLivePlayerInfoTransformer;
import de.bluecolored.bluemap.common.plugin.Plugin;
import de.bluecolored.bluemap.common.plugin.PluginState;
import de.bluecolored.bluemap.common.plugin.text.Text;
import de.bluecolored.bluemap.common.serverinterface.Gamemode;
import de.bluecolored.bluemap.common.serverinterface.Player;
import de.bluecolored.bluemap.common.serverinterface.Server;
import de.bluecolored.bluemap.common.serverinterface.ServerWorld;
import de.bluecolored.bluemap.core.map.BmMap;
import de.bluecolored.bluemap.core.storage.compression.Compression;
import de.bluecolored.bluemap.core.storage.file.FileMapStorage;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/** Run BlueMap's compiled static writer and privacy filters without a Minecraft process. */
public final class CheckBlueMapPlayers {
    private static final class FixturePlayer extends Player {
        final UUID uuid;
        final String name;
        ServerWorld world;
        Vector3d position = new Vector3d(12, 64, -4);
        Gamemode gamemode = Gamemode.SURVIVAL;
        boolean invisible, vanished;

        FixturePlayer(UUID uuid, String name, ServerWorld world) {
            this.uuid = uuid;
            this.name = name;
            this.world = world;
        }
        public UUID getUuid() { return uuid; }
        public Text getName() { return Text.of(name); }
        public ServerWorld getWorld() { return world; }
        public Vector3d getPosition() { return position; }
        public Vector3d getRotation() { return Vector3d.ZERO; }
        public int getSkyLight() { return 15; }
        public int getBlockLight() { return 15; }
        public boolean isSneaking() { return false; }
        public boolean isInvisible() { return invisible; }
        public boolean isVanished() { return vanished; }
        public Gamemode getGamemode() { return gamemode; }
    }

    private static ServerWorld world() {
        return BlueMapFixture.proxy(ServerWorld.class, (p, m, a) -> switch (m.getName()) {
            case "equals" -> p == a[0];
            default -> BlueMapFixture.unsupported(m);
        });
    }

    private static JsonArray players(Path file) throws Exception {
        return JsonParser.parseString(Files.readString(file)).getAsJsonObject().getAsJsonArray("players");
    }

    private static JsonObject player(JsonArray players, UUID uuid) {
        for (var item : players) {
            JsonObject player = item.getAsJsonObject();
            if (player.get("uuid").getAsString().equals(uuid.toString())) return player;
        }
        throw new AssertionError("missing player: " + uuid);
    }

    private static void snapshot(Path file, Path root, String name) throws Exception {
        Files.createDirectories(root.resolve("snapshots"));
        Files.copy(file, root.resolve("snapshots/" + name + ".json"));
    }

    public static void main(String[] args) throws Exception {
        Path configuration = Path.of(args[0]);
        ConfigManager loader = new ConfigManager(configuration.getParent());
        PluginConfig config = loader.loadConfig(configuration, PluginConfig.class);
        BlueMapFixture.require(config.getWritePlayersInterval() == 3 && config.getWriteMarkersInterval() == 30,
            "static player/marker schedules changed");
        BlueMapFixture.require(!config.isLivePlayerMarkers()
            && !loader.loadConfig(Path.of(args[1]), WebserverConfig.class).isEnabled(),
            "embedded live server was enabled");
        BlueMapFixture.require(config.getHiddenGameModes().equals(List.of("spectator"))
            && config.isHideVanished() && config.isHideInvisible(), "visibility protections changed");

        Path root = Path.of(args[2]);
        Path mapRoot = root.resolve("web/maps/world");
        Path file = mapRoot.resolve("live/players.json");
        ServerWorld world = world();
        Map<UUID, Player> online = new LinkedHashMap<>();
        FixturePlayer java = new FixturePlayer(new UUID(1, 1), "JavaPlayer", world);
        FixturePlayer bedrock = new FixturePlayer(new UUID(0, 2), ".BedrockPlayer", world);
        FixturePlayer spectator = new FixturePlayer(new UUID(1, 3), "spectator", world);
        FixturePlayer vanished = new FixturePlayer(new UUID(1, 4), "vanished", world);
        FixturePlayer invisible = new FixturePlayer(new UUID(1, 5), "invisible", world);
        FixturePlayer hidden = new FixturePlayer(new UUID(1, 6), "hidden", world);
        spectator.gamemode = Gamemode.SPECTATOR;
        vanished.vanished = true;
        invisible.invisible = true;
        for (FixturePlayer p : List.of(java, bedrock, spectator, vanished, invisible, hidden)) online.put(p.uuid, p);
        Server server = BlueMapFixture.proxy(Server.class, (p, m, a) -> switch (m.getName()) {
            case "getOnlinePlayers" -> online;
            case "getServerWorld" -> Optional.of(world);
            default -> BlueMapFixture.unsupported(m);
        });
        BlueMapConfiguration settings = BlueMapFixture.proxy(BlueMapConfiguration.class, (p, m, a) -> switch (m.getName()) {
            case "getPluginConfig" -> config;
            default -> BlueMapFixture.unsupported(m);
        });
        // Only replace server/bootstrap state. Serialization, filters, atomic file
        // storage and both save methods below are the actual pinned release code.
        BmMap map = BlueMapFixture.allocate(BmMap.class);
        BlueMapFixture.setField(map, "id", "world");
        BlueMapFixture.setField(map, "storage", new FileMapStorage(mapRoot, Compression.GZIP, true));
        MarkerSet offline = MarkerSet.builder().label("Offline Players").build();
        offline.getMarkers().put("logout", POIMarker.builder().label("offline").position(12, 64, -4).build());
        BlueMapFixture.setField(map, "markerSets", new ConcurrentHashMap<>(Map.of("offline-players", offline)));
        map.saveMarkerState();
        String markers = Files.readString(mapRoot.resolve("live/markers.json"));
        BlueMapService service = BlueMapFixture.allocate(BlueMapService.class);
        BlueMapFixture.setField(service, "config", settings);
        BlueMapFixture.setField(service, "maps", Map.of("world", map));
        Plugin plugin = new Plugin("paper", server);
        PluginState state = new PluginState();
        state.addHiddenPlayer(hidden.uuid);
        BlueMapFixture.setField(plugin, "blueMap", service);
        BlueMapFixture.setField(plugin, "pluginState", state);
        BlueMapFixture.setField(plugin, "loaded", true);
        BlueMapFixture.setField(plugin, "livePlayerInfoTransformer", new PluginLivePlayerInfoTransformer(plugin));

        plugin.savePlayerStates();
        JsonArray visible = players(file);
        BlueMapFixture.require(visible.size() == 2, "spectator, vanished, invisible or hidden player leaked");
        BlueMapFixture.require(player(visible, java.uuid).get("name").getAsString().equals(java.name)
            && player(visible, bedrock.uuid).get("name").getAsString().equals(bedrock.name), "Java/Bedrock names changed");
        snapshot(file, root, "online");

        java.position = new Vector3d(30, 70, -8);
        plugin.savePlayerStates();
        BlueMapFixture.require(player(players(file), java.uuid).getAsJsonObject("position").get("x").getAsDouble() == 30,
            "movement was not persisted");
        snapshot(file, root, "moved");

        bedrock.world = world();
        plugin.savePlayerStates();
        BlueMapFixture.require(player(players(file), bedrock.uuid).get("foreign").getAsBoolean()
            && !player(players(file), java.uuid).get("foreign").getAsBoolean(), "dimension visibility changed");
        snapshot(file, root, "foreign");

        online.remove(java.uuid);
        online.remove(bedrock.uuid);
        plugin.savePlayerStates();
        BlueMapFixture.require(players(file).isEmpty(), "logout left online markers behind");
        snapshot(file, root, "empty");

        // Plugin.unload invokes this method to disable players on clean stop.
        map.savePlayerState();
        BlueMapFixture.require(JsonParser.parseString(Files.readString(file)).getAsJsonObject().isEmpty(),
            "clean stop left online data behind");
        snapshot(file, root, "stopped");
        BlueMapFixture.require(markers.equals(Files.readString(mapRoot.resolve("live/markers.json"))),
            "player writes changed the offline marker layer");
        System.out.println("PASS: BlueMap static writer, Java/Bedrock, movement, dimensions, privacy, logout and clean stop");
    }
}

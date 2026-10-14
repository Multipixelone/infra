import com.kishku7.chunksmith.command.ConfigSettings;
import com.kishku7.chunksmith.lod.CsLodChunk;
import com.kishku7.chunksmith.lod.CsLodRegionStore;
import com.kishku7.chunksmith.lod.ExploredLod;
import com.kishku7.chunksmith.lod.net.CsLodHttpServer;
import com.kishku7.chunksmith.lod.net.CsLodTokens;
import com.kishku7.chunksmith.platform.Config;
import com.kishku7.chunksmith.platform.LodMode;
import java.lang.reflect.Proxy;
import java.net.ServerSocket;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;

/** Exercise the pinned upstream implementation, using only temporary CSLOD data. */
public final class CheckChunksmith {
    private static CsLodChunk chunk(String block) {
        return new CsLodChunk("minecraft:overworld", 0, 0, 0,
                List.of(block), List.of("minecraft:plains"),
                List.of(new CsLodChunk.Section(null, 0, null, 0, null, 15, null, 0)));
    }

    private static HttpResponse<byte[]> request(HttpClient client, String base, String path,
                                                String method, String token, String... headers)
            throws Exception {
        HttpRequest.Builder builder = HttpRequest.newBuilder(URI.create(base + path))
                .timeout(Duration.ofSeconds(5))
                .method(method, HttpRequest.BodyPublishers.noBody());
        if (token != null) builder.header("X-Chunksmith-Token", token);
        for (int i = 0; i < headers.length; i += 2) builder.header(headers[i], headers[i + 1]);
        return client.send(builder.build(), HttpResponse.BodyHandlers.ofByteArray());
    }

    public static void main(String[] args) throws Exception {
        Config config = (Config) Proxy.newProxyInstance(Config.class.getClassLoader(),
                new Class<?>[] {Config.class}, (proxy, method, values) -> {
                    Class<?> type = method.getReturnType();
                    if (type == boolean.class) return false;
                    if (type == long.class) return 0L;
                    if (type == int.class) return 0;
                    if (type == double.class) return 0.0;
                    if (type == LodMode.class) return LodMode.AUTO;
                    if (type == String.class) return "";
                    return null;
                });
        for (int i = 1; i < args.length; i++) {
            String[] pair = args[i].split("=", 2);
            assert ConfigSettings.find(pair[0]).orElseThrow().write(config, pair[1]) : args[i];
        }
        assert ConfigSettings.find("forceLoadExistingChunks").orElseThrow().write(config, "true");
        assert ExploredLod.shouldTake(true, true, true, true, false);
        assert !ExploredLod.shouldTake(true, true, true, true, true) : "cached terrain is deliberately skipped";
        assert !ExploredLod.shouldTake(false, true, true, true, false) : "installation does not capture explored chunks";

        Path root = Path.of(args[0]).resolve("store");
        Path dimension = root.resolve("minecraft_overworld");
        Files.createDirectories(dimension);
        CsLodRegionStore store = new CsLodRegionStore(dimension);
        try {
            store.write(chunk("minecraft:stone"));
            long before = Files.size(dimension.resolve("r.0.0.cslod"));
            store.write(chunk("minecraft:gold_block"));
            assert store.read(0, 0).getBlockPalette().equals(List.of("minecraft:gold_block"));
            assert Files.size(dimension.resolve("r.0.0.cslod")) > before : "refresh appends without compaction";
        } finally {
            store.close();
        }

        UUID player = UUID.randomUUID();
        CsLodTokens tokens = new CsLodTokens();
        AtomicBoolean online = new AtomicBoolean(true);
        String token = tokens.issue(player, "127.0.0.1");
        assert tokens.validate(token, "127.0.0.1", uuid -> online.get()).equals(player);
        assert tokens.validate(token, "127.0.0.2", uuid -> true) == null;
        assert tokens.validate(token, "127.0.0.1", uuid -> false) == null;
        String old = token;
        token = tokens.issue(player, "127.0.0.1");
        assert tokens.validate(old, "127.0.0.1", uuid -> true) == null;

        // Use the actual listener on a disposable loopback port, never the live endpoint.
        int port;
        try (ServerSocket socket = new ServerSocket(0)) { port = socket.getLocalPort(); }
        CsLodHttpServer server = new CsLodHttpServer(root, tokens, uuid -> online.get());
        assert server.start("127.0.0.1", 0, port, "127.0.0.1") == port;
        try (HttpClient client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build()) {
            String base = "http://127.0.0.1:" + port;
            String path = "/lod/minecraft_overworld/r.0.0.cslod";
            byte[] contents = Files.readAllBytes(dimension.resolve("r.0.0.cslod"));
            assert request(client, base, path, "GET", null).statusCode() == 404;
            assert request(client, base, path, "GET", "invalid").statusCode() == 404;
            HttpResponse<byte[]> response = request(client, base, path, "GET", token);
            assert response.statusCode() == 200 && Arrays.equals(response.body(), contents);
            response = request(client, base, path, "GET", token, "Range", "bytes=0-15");
            assert response.statusCode() == 206 && Arrays.equals(response.body(), Arrays.copyOf(contents, 16));
            response = request(client, base, path, "HEAD", token);
            assert response.statusCode() == 200 && response.body().length == 0;
            assert request(client, base, path, "POST", token).statusCode() == 404;
            assert request(client, base, "/lod/minecraft_overworld/", "GET", token).statusCode() == 404;
            assert request(client, base, "/lod/../r.0.0.cslod", "GET", token).statusCode() == 404;
            String wrongIp = tokens.issue(UUID.randomUUID(), "192.0.2.1");
            assert request(client, base, path, "GET", wrongIp,
                    "X-Forwarded-For", "192.0.2.1").statusCode() == 404;
            online.set(false);
            assert request(client, base, path, "GET", token).statusCode() == 404;
            online.set(true);
            tokens.revoke(player);
            assert request(client, base, path, "GET", token).statusCode() == 404;
        } finally {
            server.stop();
        }

        // Expire a synthetic token without sleeping for ten minutes.
        String expired = tokens.issue(player, "127.0.0.1");
        var field = CsLodTokens.class.getDeclaredField("byToken");
        field.setAccessible(true);
        @SuppressWarnings("unchecked")
        Map<String, Object> entries = (Map<String, Object>) field.get(tokens);
        var constructor = entries.get(expired).getClass().getDeclaredConstructor(UUID.class, String.class, long.class);
        constructor.setAccessible(true);
        entries.put(expired, constructor.newInstance(player, "127.0.0.1", 0L));
        assert tokens.validate(expired, "127.0.0.1", uuid -> true) == null;
        tokens.clear();
        assert tokens.size() == 0;
        System.out.println("Pinned upstream config, cache replacement, HTTP ranges and IP/session/expiry authentication passed");
    }
}

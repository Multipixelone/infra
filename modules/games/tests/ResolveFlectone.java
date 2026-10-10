import java.lang.reflect.Proxy;
import java.net.URL;
import java.net.URLConnection;
import java.net.URLStreamHandler;
import java.nio.file.Path;
import org.bukkit.plugin.Plugin;
import net.flectone.pulse.BuildConfig;
import net.flectone.pulse.logging.FLogger;
import net.flectone.pulse.platform.adapter.LogAdapter;
import net.flectone.pulse.resolver.BukkitLibraryResolver;
import net.flectone.pulse.library.libby.Library;

// Exercise the pinned plugin's actual Bukkit dependency declarations and Maven
// resolver against the immutable cache, rejecting every HTTP connection.
public class ResolveFlectone extends BukkitLibraryResolver {
    private int libraries;

    ResolveFlectone(Path directory) {
        super(new FLogger(new LogAdapter() {
            public void log(net.flectone.pulse.library.libby.logging.LogLevel level, String text, boolean flag) {}
            public void log(net.flectone.pulse.library.libby.logging.LogLevel level, String text, Throwable error, boolean flag) {}
        }, () -> null), (Plugin) Proxy.newProxyInstance(Plugin.class.getClassLoader(), new Class<?>[]{Plugin.class},
            (proxy, method, args) -> method.getName().equals("getDataFolder") ? directory.toFile() : null));
    }

    protected void addToClasspath(Path path) { libraries++; }

    public static void main(String[] args) throws Exception {
        URL.setURLStreamHandlerFactory(protocol -> {
            if (!protocol.equals("https") && !protocol.equals("http")) return null;
            return new URLStreamHandler() {
                protected URLConnection openConnection(URL url) {
                    throw new AssertionError("NETWORK ATTEMPT: " + url);
                }
            };
        });
        ResolveFlectone resolver = new ResolveFlectone(Path.of(args[0]));
        resolver.resolveRepositories();
        resolver.loadLibraries();
        resolver.loadLibrary(Library.builder()
            .groupId("com{}h2database").artifactId("h2").version(BuildConfig.H2_VERSION)
            .repository(BuildConfig.MAVEN_REPOSITORY).resolveTransitiveDependencies(true)
            .excludeTransitiveDependency("org.slf4j", "slf4j-api")
            .isolatedLoad(true).loaderId("h2").build());
        if (resolver.libraries != 93) throw new AssertionError("Incomplete cache: " + resolver.libraries);
        Class.forName("org.h2.Driver", true, resolver.getIsolatedClassLoaderById("h2"));
        System.out.println("PASS: actual Bukkit resolver, " + resolver.libraries + " runtime libraries, H2 driver, zero HTTP attempts");
    }
}

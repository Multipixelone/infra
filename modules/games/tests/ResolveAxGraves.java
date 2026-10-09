import java.net.URL;
import java.net.URLConnection;
import java.net.URLStreamHandler;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.jar.JarFile;
import com.artillexstudios.axgraves.libs.axapi.libraries.Library;
import com.artillexstudios.axgraves.libs.axapi.libraries.LibraryDownloader;
import com.artillexstudios.axgraves.libs.axapi.libraries.Relocation;

// Exercise AxAPI's real initialization and cache lookup, denying all HTTP.
public class ResolveAxGraves {
    public static void main(String[] args) throws Exception {
        URL.setURLStreamHandlerFactory(protocol -> {
            if (!protocol.equals("https") && !protocol.equals("http")) return null;
            return new URLStreamHandler() {
                protected URLConnection openConnection(URL url) {
                    throw new AssertionError("NETWORK ATTEMPT: " + url);
                }
            };
        });
        com.artillexstudios.axgraves.libs.axapi.utils.featureflags.FeatureFlags.refresh();
        Path cache = Path.of(args[0]);
        LibraryDownloader d = new LibraryDownloader(cache, true);
        d.addRelocation(new Relocation("org.apache.commons.math3", "com.artillexstudios.axgraves.libs.axapi.libs.math3"));
        d.addRelocation(new Relocation("com.github.benmanes", "com.artillexstudios.axgraves.libs.axapi.libs.caffeine"));
        d.addRelocation(new Relocation("com.artillexstudios.axapi", "com.artillexstudios.axgraves.libs.axapi"));
        d.addLibrary(new Library("org.apache.commons", "commons-math3", "3.6.1", "", List.of()));
        d.addLibrary(new Library("com.github.ben-manes.caffeine", "caffeine", "3.2.3", "", List.of()));
        d.addLibrary(new Library("com.artillexstudios.axapi.nms.v26_3", "axapi", "2.2.0-DEV-NEW-VERSION-6", "all", List.of()));
        Set<Path> paths = new HashSet<>(d.getLibraryPaths());
        if (paths.size() != 8) throw new AssertionError("Expected 8 libraries, got " + paths.size());
        check(cache.resolve("org.apache.commons.commons-math3-3.6.1.jar"),
            "com/artillexstudios/axgraves/libs/axapi/libs/math3/util/FastMath.class",
            "org/apache/commons/math3/util/FastMath.class");
        check(cache.resolve("com.github.ben-manes.caffeine.caffeine-3.2.3.jar"),
            "com/artillexstudios/axgraves/libs/axapi/libs/caffeine/caffeine/cache/Caffeine.class",
            "com/github/benmanes/caffeine/cache/Caffeine.class");
        try (JarFile j = new JarFile(cache.resolve("com.artillexstudios.axapi.nms.v26_3.axapi-2.2.0-DEV-NEW-VERSION-6-all.jar").toFile())) {
            if (j.stream().noneMatch(e -> e.getName().startsWith("com/artillexstudios/axgraves/libs/axapi/nms/")))
                throw new AssertionError("Missing relocated NMS");
            if (j.stream().anyMatch(e -> e.getName().startsWith("com/artillexstudios/axapi/")))
                throw new AssertionError("Unrelocated AxAPI");
        }
        System.out.println("PASS: actual AxAPI cache loader, 8 libraries, exact relocations, zero HTTP attempts");
    }

    static void check(Path path, String present, String absent) throws Exception {
        try (JarFile j = new JarFile(path.toFile())) {
            if (j.getEntry(present) == null || j.getEntry(absent) != null)
                throw new AssertionError("Relocation wrong: " + path);
        }
    }
}

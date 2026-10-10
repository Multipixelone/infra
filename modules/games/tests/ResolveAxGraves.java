import java.net.URL;
import java.net.URLClassLoader;
import java.net.URLConnection;
import java.net.URLStreamHandler;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.Set;
import java.util.jar.JarFile;
import com.artillexstudios.axgraves.libs.axapi.dependencies.DependencyManagerWrapper;
import com.artillexstudios.axgraves.libs.axapi.dependencies.UnsafeDependencyLoader;
import com.artillexstudios.axgraves.libs.axapi.libraries.LibraryDownloader;

// Exercise production dependency identities and classpath attachment, denying HTTP.
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
        if (Files.isSymbolicLink(cache) || Files.isSymbolicLink(cache.resolve("cache.yml")))
            throw new AssertionError("Metadata must be a writable runtime copy");
        // Match AxPlugin's default constructor and wrapper calls. Three-part
        // coordinates produce a null classifier, not an empty string.
        LibraryDownloader d = new LibraryDownloader(cache);
        DependencyManagerWrapper dependencies = new DependencyManagerWrapper(d);
        dependencies.repository("https://repo.artillex-studios.com/releases/");
        dependencies.relocate("org{}apache{}commons{}math3", "com.artillexstudios.axgraves.libs.axapi.libs.math3");
        dependencies.relocate("com{}github{}benmanes", "com.artillexstudios.axgraves.libs.axapi.libs.caffeine");
        dependencies.relocate("com{}artillexstudios{}axapi", "com.artillexstudios.axgraves.libs.axapi");
        dependencies.dependency("com{}artillexstudios{}axapi{}nms{}v26_3:axapi:2.2.0-DEV-NEW-VERSION-6:all");
        dependencies.dependency("org{}apache{}commons:commons-math3:3.6.1");
        dependencies.dependency("com{}github{}ben-manes{}caffeine:caffeine:3.2.3");
        Set<Path> paths = new HashSet<>(d.getLibraryPaths());
        Set<Path> expected = new HashSet<>();
        for (String name : new String[]{
                "org.ow2.asm.asm-commons-9.10.1.jar", "org.ow2.asm.asm-9.10.1.jar",
                "me.lucko.jar-relocator-1.7.jar", "org.apache.commons.commons-math3-3.6.1.jar",
                "com.github.ben-manes.caffeine.caffeine-3.2.3.jar", "org.jspecify.jspecify-1.0.0.jar",
                "com.google.errorprone.error_prone_annotations-2.43.0.jar",
                "com.artillexstudios.axapi.nms.v26_3.axapi-2.2.0-DEV-NEW-VERSION-6-all.jar"})
            expected.add(cache.resolve(name));
        if (!paths.equals(expected)) throw new AssertionError("Incomplete runtime libraries: " + paths);
        try (URLClassLoader loader = new URLClassLoader(new URL[0], ResolveAxGraves.class.getClassLoader())) {
            String prefix = "com.artillexstudios.axgraves.libs.axapi.libs.";
            String caffeineName = prefix + "caffeine.caffeine.cache.Caffeine";
            if (loader.getResource(caffeineName.replace('.', '/') + ".class") != null)
                throw new AssertionError("Test classpath already supplies Caffeine");
            UnsafeDependencyLoader attachment = new UnsafeDependencyLoader();
            for (Path path : paths) {
                if (!Files.isSymbolicLink(path)) throw new AssertionError("Jar cache was replaced: " + path);
                attachment.loadUnsafeLibrary(loader, path);
            }
            Class<?> caffeine = load(loader, caffeineName, cache.resolve("com.github.ben-manes.caffeine.caffeine-3.2.3.jar"));
            Object builder = caffeine.getMethod("newBuilder").invoke(null);
            Object instance = caffeine.getMethod("build").invoke(builder);
            Class<?> cacheApi = loader.loadClass(prefix + "caffeine.caffeine.cache.Cache");
            cacheApi.getMethod("put", Object.class, Object.class).invoke(instance, "grave", "items");
            if (!"items".equals(cacheApi.getMethod("getIfPresent", Object.class).invoke(instance, "grave")))
                throw new AssertionError("Caffeine cache did not retain items");
            Class<?> math = load(loader, prefix + "math3.util.FastMath", cache.resolve("org.apache.commons.commons-math3-3.6.1.jar"));
            if (!Double.valueOf(3).equals(math.getMethod("sqrt", double.class).invoke(null, 9.0)))
                throw new AssertionError("Relocated math library failed");
            load(loader, "com.artillexstudios.axgraves.libs.axapi.nms.v26_3.NMSHandler",
                cache.resolve("com.artillexstudios.axapi.nms.v26_3.axapi-2.2.0-DEV-NEW-VERSION-6-all.jar"));
        }
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
        System.out.println("PASS: actual AxAPI dependency wrapper, writable metadata, 8 runtime libraries, relocated class loading, zero HTTP attempts");
    }

    static Class<?> load(URLClassLoader loader, String name, Path jar) throws Exception {
        Class<?> clazz = Class.forName(name, false, loader);
        Path origin = Path.of(clazz.getProtectionDomain().getCodeSource().getLocation().toURI());
        if (clazz.getClassLoader() != loader || !Files.isSameFile(origin, jar))
            throw new AssertionError("Class did not load from pinned runtime library: " + name);
        return clazz;
    }

    static void check(Path path, String present, String absent) throws Exception {
        try (JarFile j = new JarFile(path.toFile())) {
            if (j.getEntry(present) == null || j.getEntry(absent) != null)
                throw new AssertionError("Relocation wrong: " + path);
        }
    }
}

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.logging.Logger;
import carbonchat.libs.xyz.jpenilla.gremlin.runtime.DependencyCache;
import carbonchat.libs.xyz.jpenilla.gremlin.runtime.DependencyResolver;
import carbonchat.libs.xyz.jpenilla.gremlin.runtime.DependencySet;
import carbonchat.libs.xyz.jpenilla.gremlin.runtime.logging.JavaGremlinLogger;

// Exercise the release's real Gremlin resolver with no repository URLs.
public class ResolveCarbon {
    public static void main(String[] args) throws Exception {
        var original = DependencySet.readFromClasspathResource(
            ResolveCarbon.class.getClassLoader(), "carbon-dependencies.txt");
        if (!original.extensionData().isEmpty()) throw new AssertionError("Unexpected relocation extensions");
        var offline = new DependencySet(List.of(), original.dependencies(),
            original.extensions(), original.extensionData());
        var fixture = Path.of(args[1]);
        for (var jar : Files.walk(Path.of(args[0])).filter(p -> p.toString().endsWith(".jar")).toList()) {
            var target = fixture.resolve(Path.of(args[0]).relativize(jar));
            Files.createDirectories(target.getParent());
            Files.createSymbolicLink(target, jar.toAbsolutePath());
        }
        try (var resolver = new DependencyResolver(new JavaGremlinLogger(Logger.getLogger("offline")))) {
            var jars = resolver.resolve(offline, new DependencyCache(fixture)).jarFiles();
            if (jars.size() != original.dependencies().size() || jars.size() != 35)
                throw new AssertionError("Missing pinned runtime libraries: " + jars.size());
            for (var jar : jars) {
                if (!Files.isSymbolicLink(jar)) throw new AssertionError("Cache was replaced: " + jar);
                if (!Files.exists(jar.resolveSibling(jar.getFileName() + ".last-used.txt")))
                    throw new AssertionError("Missing writable Gremlin timestamp: " + jar);
            }
        }
        System.out.println("PASS: Carbon's real Gremlin resolver, 35 pinned jars, no repositories, writable timestamps");
    }
}

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.List;
import de.miraculixx.veinminer.VeinminerLoader;
import io.papermc.paper.plugin.loader.PluginClasspathBuilder;
import io.papermc.paper.plugin.loader.library.ClassPathLibrary;
import io.papermc.paper.plugin.bootstrap.PluginProviderContext;
import org.eclipse.aether.DefaultRepositorySystemSession;
import org.eclipse.aether.transfer.AbstractTransferListener;
import org.eclipse.aether.transfer.TransferEvent;

// Resolve the release's own dependency declarations against the deployed cache.
public class ResolveVeinminer {
    public static void main(String[] args) throws Exception {
        List<ClassPathLibrary> libraries = new ArrayList<>();
        new VeinminerLoader().classloader(new PluginClasspathBuilder() {
            public PluginClasspathBuilder addLibrary(ClassPathLibrary lib) {
                libraries.add(lib);
                return this;
            }
            public PluginProviderContext getContext() { return null; }
        });
        if (libraries.size() != 1) throw new AssertionError("Unexpected loader libraries");
        for (ClassPathLibrary lib : libraries) {
            Field field = lib.getClass().getDeclaredField("session");
            field.setAccessible(true);
            var session = (DefaultRepositorySystemSession) field.get(lib);
            Field listener = DefaultRepositorySystemSession.class.getDeclaredField("transferListener");
            listener.setAccessible(true);
            listener.set(session, new AbstractTransferListener() {
                public void transferInitiated(TransferEvent event) {
                    throw new AssertionError("NETWORK ATTEMPT: " + event.getResource());
                }
            });
            lib.register(path -> System.out.println("LIBRARY " + path.toAbsolutePath()));
        }
        System.out.println("PASS: release Paper loader, zero transfers");
    }
}

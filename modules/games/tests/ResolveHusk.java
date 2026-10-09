import java.util.ArrayList;
import java.util.List;
import java.lang.reflect.Field;
import io.papermc.paper.plugin.loader.PluginClasspathBuilder;
import io.papermc.paper.plugin.loader.library.ClassPathLibrary;
import io.papermc.paper.plugin.bootstrap.PluginProviderContext;
import net.william278.huskhomes.PaperHuskHomesLoader;
import org.eclipse.aether.DefaultRepositorySystemSession;
import org.eclipse.aether.transfer.AbstractTransferListener;
import org.eclipse.aether.transfer.TransferEvent;

// Exercise the pinned plugin's real Paper loader, without starting the server.
public class ResolveHusk {
    public static void main(String[] args) throws Exception {
        List<ClassPathLibrary> libs = new ArrayList<>();
        new PaperHuskHomesLoader().classloader(new PluginClasspathBuilder() {
            public PluginClasspathBuilder addLibrary(ClassPathLibrary lib) {
                libs.add(lib);
                return this;
            }
            public PluginProviderContext getContext() { return null; }
        });
        if (libs.isEmpty()) throw new AssertionError("No libraries");
        int[] count = {0};
        for (ClassPathLibrary lib : libs) {
            // Replace the listener in the pinned resolver's read-only session.
            Field sessionField = lib.getClass().getDeclaredField("session");
            sessionField.setAccessible(true);
            DefaultRepositorySystemSession session = (DefaultRepositorySystemSession) sessionField.get(lib);
            Field listenerField = DefaultRepositorySystemSession.class.getDeclaredField("transferListener");
            listenerField.setAccessible(true);
            listenerField.set(session, new AbstractTransferListener() {
                public void transferInitiated(TransferEvent event) {
                    throw new AssertionError("NETWORK ATTEMPT: " + event.getResource());
                }
            });
            lib.register(p -> { count[0]++; });
        }
        if (count[0] != 14) throw new AssertionError("Expected 14 jars, got " + count[0]);
        System.out.println("PASS: actual Paper resolver, 14 runtime jars, zero transfers");
    }
}

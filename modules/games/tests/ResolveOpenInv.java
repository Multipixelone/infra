import java.io.InputStream;
import java.lang.reflect.Field;
import java.net.URLClassLoader;
import java.util.logging.Logger;
import java.util.zip.ZipFile;
import org.bukkit.plugin.PluginDescriptionFile;
import org.bukkit.plugin.java.LibraryLoader;
import org.eclipse.aether.DefaultRepositorySystemSession;
import org.eclipse.aether.transfer.AbstractTransferListener;
import org.eclipse.aether.transfer.TransferEvent;

// Exercise the exact Paper Bukkit-library loader and pinned plugin descriptor.
public class ResolveOpenInv {
    public static void main(String[] args) throws Exception {
        PluginDescriptionFile description;
        try (ZipFile jar = new ZipFile(args[0]);
             InputStream descriptor = jar.getInputStream(jar.getEntry("plugin.yml"))) {
            description = new PluginDescriptionFile(descriptor);
        }
        if (!description.getVersion().equals("5.3.5")) {
            throw new AssertionError("Unexpected OpenInv version");
        }
        LibraryLoader loader = new LibraryLoader(Logger.getLogger("OpenInvOfflineTest"));
        Field sessionField = LibraryLoader.class.getDeclaredField("session");
        sessionField.setAccessible(true);
        DefaultRepositorySystemSession session = (DefaultRepositorySystemSession) sessionField.get(loader);
        Field listenerField = DefaultRepositorySystemSession.class.getDeclaredField("transferListener");
        listenerField.setAccessible(true);
        listenerField.set(session, new AbstractTransferListener() {
            public void transferInitiated(TransferEvent event) {
                throw new AssertionError("NETWORK ATTEMPT: " + event.getResource());
            }
        });
        try (URLClassLoader libraries = (URLClassLoader) loader.createLoader(description)) {
            if (libraries.getURLs().length != 1
                    || !libraries.getURLs()[0].toString().endsWith("sqlite-jdbc-3.49.1.0.jar")) {
                throw new AssertionError("Unexpected resolved OpenInv libraries");
            }
            Class.forName("org.sqlite.JDBC", true, libraries);
        }
        System.out.println("PASS: pinned OpenInv descriptor, Paper LibraryLoader, SQLite driver, zero transfers");
    }
}

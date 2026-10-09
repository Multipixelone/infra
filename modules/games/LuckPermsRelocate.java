import java.io.File;
import java.util.ArrayList;
import me.lucko.jarrelocator.JarRelocator;
import me.lucko.jarrelocator.Relocation;

// Run only in a Nix build, never during server startup.
class LuckPermsRelocate {
    public static void main(String[] args) throws Exception {
        var rules = new ArrayList<Relocation>();
        for (int i = 2; i < args.length; i += 2)
            rules.add(new Relocation(args[i], args[i + 1]));
        new JarRelocator(new File(args[0]), new File(args[1]), rules).run();
    }
}

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import de.miraculixx.veinminer.data.*;
import de.miraculixx.veinminer.pattern.*;
import kotlinx.serialization.builtins.BuiltinSerializersKt;
import kotlinx.serialization.json.Json;
import net.minecraft.resources.Identifier;

// Run the release's strict serializer and real traversal, with a value-only NMS
// Identifier fixture. No Minecraft world or plugin gameplay code is replaced.
public class ReadVeinminer {
    static void require(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    public static void main(String[] args) throws Exception {
        var settings = Json.Default.decodeFromString(VeinminerSettings.Companion.serializer(),
            Files.readString(Path.of(args[0])));
        require(settings.getMustSneak(), "not sneak-only");
        require(settings.getNeedCorrectTool(), "incorrect tools allowed");
        require(settings.getDecreaseDurability(), "durability disabled");
        require(settings.getMaxChain() == 64 && settings.getSearchRadius() == 1, "unsafe limits");
        require(settings.getSeparateGroupMining(), "mixed material mining");
        require(settings.getPermissionRestricted(), "permissions disabled");
        require(!settings.getClient().getAllow() && !settings.getClient().getRequire()
            && !settings.getClient().getAllBlocks(), "client bypass or requirement");
        require(settings.getClient().getOverrides().nonNullKeys().isEmpty(), "client overrides");
        require(!settings.getAutoUpdate() && settings.getHideUpdates(), "update settings");

        var strings = BuiltinSerializersKt.serializer(kotlin.jvm.internal.StringCompanionObject.INSTANCE);
        var groups = Json.Default.decodeFromString(
            BuiltinSerializersKt.ListSerializer(BlockGroup.Companion.serializer(strings)),
            Files.readString(Path.of(args[1])));
        require(groups.size() == 2, "wrong groups");
        for (var group : groups) {
            require(group.getTools().equals(Set.of("#minecraft:pickaxes")), "wrong tools");
            require(group.getOverride().nonNullKeys().isEmpty(), "group overrides");
            for (String type : group.getBlocks()) checkTraversal(settings, type);
        }
        System.out.println("PASS: release serializers, 21 materials, traversal cap, preview, isolation, abort");
    }

    static void checkTraversal(VeinminerSettings settings, String type) {
        var target = new Identifier(type);
        var other = new Identifier("minecraft:stone");
        var origin = new BlockPosition(0, 0, 0);
        var action = new VeinmineAction<>(origin, Set.of(target), new Object(), new Object(),
            origin, settings, Surface.UP);
        List<BlockPosition> broken = new ArrayList<>();
        var world = new BlockAwareness() {
            public Identifier getBlockType(BlockPosition pos) {
                return pos.getY() == 0 && pos.getZ() == 0 && pos.getX() >= 0 && pos.getX() < 100
                    ? target : other;
            }
            public boolean breakBlock(BlockPosition pos, int ticks) {
                require(getBlockType(pos).equals(target), "wrong material broken");
                broken.add(pos);
                return true;
            }
        };
        var preview = Veinmining.INSTANCE.veinmine(action, world, NormalStrategy.INSTANCE, Integer.MAX_VALUE, false);
        require(preview.size() == 64 && broken.isEmpty(), "preview cap or side effect: " + type);
        var hits = Veinmining.INSTANCE.veinmine(action, world, NormalStrategy.INSTANCE, Integer.MAX_VALUE, true);
        require(hits.size() == 64 && broken.size() == 63, "cap must include original: " + type);
        require(!broken.contains(origin), "original block broken twice");
        int[] attempts = {0};
        var stopped = new BlockAwareness() {
            public Identifier getBlockType(BlockPosition pos) { return world.getBlockType(pos); }
            public boolean breakBlock(BlockPosition pos, int ticks) { attempts[0]++; return false; }
        };
        Veinmining.INSTANCE.veinmine(action, stopped, NormalStrategy.INSTANCE, Integer.MAX_VALUE, true);
        require(attempts[0] == 1, "traversal did not stop after failed break");
    }
}

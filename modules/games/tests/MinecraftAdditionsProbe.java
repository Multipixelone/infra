import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.moulberry.axiom.AxiomPaper;
import com.moulberry.axiom.restrictions.AxiomPermission;
import com.badbones69.crazyenchantments.paper.CrazyEnchantments;
import java.lang.reflect.Proxy;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import me.szabee.doubledoors.bukkit.DoubleDoors;
import me.szabee.doubledoors.bukkit.config.PluginConfig;
import me.szabee.doubledoors.bukkit.listeners.DoorInteractListener;
import net.kyori.adventure.util.TriState;
import net.luckperms.api.LuckPermsProvider;
import net.luckperms.api.model.user.User;
import net.luckperms.api.node.Node;
import net.luckperms.api.node.types.InheritanceNode;
import net.luckperms.api.util.Tristate;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.Identifier;
import net.minecraft.world.level.block.Blocks;
import org.bukkit.Bukkit;
import org.bukkit.Material;
import org.bukkit.World;
import org.bukkit.block.Block;
import org.bukkit.block.BlockFace;
import org.bukkit.block.data.Bisected;
import org.bukkit.block.data.type.Door;
import org.bukkit.entity.Player;
import org.bukkit.permissions.Permission;
import org.bukkit.plugin.java.JavaPlugin;

/** No client connections, production database, or live server state. */
public final class MinecraftAdditionsProbe extends JavaPlugin {
    private JsonObject expectations;

    private void check(boolean condition, String label) {
        if (!condition) throw new AssertionError(label);
        getLogger().info("PASS " + label);
    }

    private JsonObject json(String resource) throws Exception {
        try (var input = getResource(resource)) {
            return new Gson().fromJson(new String(input.readAllBytes(), StandardCharsets.UTF_8), JsonObject.class);
        }
    }

    private Object empty(Class<?> type) {
        if (!type.isPrimitive()) return null;
        if (type == boolean.class) return false;
        if (type == int.class) return 0;
        if (type == long.class) return 0L;
        if (type == double.class) return 0d;
        if (type == float.class) return 0f;
        if (type == byte.class) return (byte) 0;
        if (type == short.class) return (short) 0;
        return '\0';
    }

    private Player player(User user, World world) {
        return (Player) Proxy.newProxyInstance(getClass().getClassLoader(), new Class<?>[] { Player.class }, (proxy, method, args) -> {
            return switch (method.getName()) {
                case "getName", "getDisplayName" -> user.getUsername();
                case "getUniqueId" -> user.getUniqueId();
                case "getWorld" -> world;
                case "getGameMode" -> org.bukkit.GameMode.CREATIVE;
                case "getLocale" -> "en_us";
                case "locale" -> java.util.Locale.US;
                case "isOnline", "isValid" -> true;
                case "getEffectivePermissions" -> Set.of();
                case "getMetadata" -> List.of();
                case "permissionValue", "hasPermission", "isPermissionSet" -> {
                    String node = args[0] instanceof Permission permission ? permission.getName() : args[0].toString();
                    Tristate value = user.getCachedData().getPermissionData().checkPermission(node);
                    if (method.getName().equals("permissionValue")) {
                        yield switch (value) { case TRUE -> TriState.TRUE; case FALSE -> TriState.FALSE; default -> TriState.NOT_SET; };
                    }
                    if (method.getName().equals("isPermissionSet")) yield value != Tristate.UNDEFINED;
                    if (value != Tristate.UNDEFINED) yield value == Tristate.TRUE;
                    Permission permission = Bukkit.getPluginManager().getPermission(node);
                    yield permission != null && permission.getDefault().getValue(false);
                }
                case "hashCode" -> user.getUniqueId().hashCode();
                case "equals" -> proxy == args[0];
                case "toString" -> "AdditionsProbePlayer[" + user.getUsername() + "]";
                default -> empty(method.getReturnType());
            };
        });
    }

    private void seedPermissions() throws Exception {
        var api = LuckPermsProvider.get();
        JsonObject bootstrap = json("bootstrap.json");
        for (var entry : bootstrap.getAsJsonObject("groups").entrySet()) {
            var group = api.getGroupManager().createAndLoadGroup(entry.getKey()).join();
            group.data().clear();
            for (var value : entry.getValue().getAsJsonObject().getAsJsonArray("nodes")) {
                var node = value.getAsJsonObject();
                group.data().add(Node.builder(node.get("key").getAsString()).value(node.get("value").getAsBoolean()).build());
            }
            api.getGroupManager().saveGroup(group).join();
        }
        for (String rank : List.of("default", "builder", "mod", "admin")) {
            UUID uuid = UUID.nameUUIDFromBytes(("additions-" + rank).getBytes(StandardCharsets.UTF_8));
            User user = api.getUserManager().loadUser(uuid, "Probe_" + rank).join();
            user.data().clear();
            user.data().add(InheritanceNode.builder(rank).build());
            api.getUserManager().saveUser(user).join();
            user.getCachedData().invalidate();
        }
    }

    private Player rankPlayer(String rank, World world) {
        UUID uuid = UUID.nameUUIDFromBytes(("additions-" + rank).getBytes(StandardCharsets.UTF_8));
        return player(LuckPermsProvider.get().getUserManager().getUser(uuid), world);
    }

    private void permissions(AxiomPaper axiom, World world) {
        for (String rank : List.of("default", "builder", "mod", "admin")) {
            Player player = rankPlayer(rank, world);
            boolean builder = !rank.equals("default");
            boolean admin = rank.equals("admin");
            for (String node : List.of("doubledoors.use", "doubledoors.toggle", "crazyenchantments.player.*",
                    "crazyenchantments.gui", "crazyenchantments.tinker", "crazyenchantments.info")) {
                check(player.hasPermission(node), rank + " grant " + node);
            }
            for (var value : expectations.getAsJsonArray("grants")) {
                String node = value.getAsString();
                check(player.hasPermission(node) == builder, rank + " grant " + node);
            }
            check(player.hasPermission("axiom.all") == admin, rank + " axiom.all");
            check(player.hasPermission("axiom.default") == admin, rank + " axiom.default");
            for (var value : expectations.getAsJsonArray("denials")) {
                String node = value.getAsString();
                // Explicit builder denials also inherit to admin. Axiom's own
                // ALL permission is what makes admin unrestricted internally.
                if (!admin) check(!player.hasPermission(node), rank + " denial " + node);
            }
            for (AxiomPermission permission : AxiomPermission.values()) {
                String node = permission.getPermissionNode();
                boolean expectedGrant = admin || (builder && expectations.getAsJsonArray("grants").asList().stream()
                        .map(value -> value.getAsString()).anyMatch(grant -> grant.endsWith(".*")
                                ? node.startsWith(grant.substring(0, grant.length() - 1)) : node.equals(grant)));
                check(axiom.hasPermission(player, permission) == expectedGrant, rank + " Axiom evaluates " + node);
            }
        }
    }

    private void door(Block bottom, Door.Hinge hinge) {
        bottom.getRelative(BlockFace.DOWN).setType(Material.STONE, false);
        for (var half : Bisected.Half.values()) {
            Block block = half == Bisected.Half.BOTTOM ? bottom : bottom.getRelative(BlockFace.UP);
            Door data = (Door) Bukkit.createBlockData(Material.OAK_DOOR);
            data.setFacing(BlockFace.NORTH);
            data.setHinge(hinge);
            data.setHalf(half);
            block.setBlockData(data, false);
        }
    }

    private void doors(World world) throws Exception {
        var plugin = (DoubleDoors) Bukkit.getPluginManager().getPlugin("DoubleDoors");
        check(plugin.getPluginConfig().isEnableRecursiveOpening(), "paired-door click handler enabled");
        Player player = rankPlayer("default", world);
        check(!Bukkit.getPluginManager().isPluginEnabled("floodgate"), "no backend Floodgate");
        check(!plugin.isGeyserBridgeAvailable(), "proxy-only setup has no local bridge detection");
        Block origin = world.getBlockAt(0, 70, 0);
        Block partner = world.getBlockAt(1, 70, 0);
        door(origin, Door.Hinge.LEFT);
        door(partner, Door.Hinge.RIGHT);
        check(plugin.getApi().triggerLinkedOpen(origin, player), "default player opens linked door");
        check(((Door) partner.getBlockData()).isOpen(), "partner bottom opens");
        check(((Door) partner.getRelative(BlockFace.UP).getBlockData()).isOpen(), "partner top opens");
        // Check the actual release's duplicate guard without installing a fake
        // bridge or relying on a timed sleep to reproduce duplicate packets.
        var listener = new DoorInteractListener(plugin);
        var limiter = DoorInteractListener.class.getDeclaredMethod("isInteractionRateLimited", Player.class, Block.class, PluginConfig.class);
        limiter.setAccessible(true);
        check(!(boolean) limiter.invoke(listener, player, origin, plugin.getPluginConfig()), "first interaction accepted without bridge");
        check((boolean) limiter.invoke(listener, player, origin, plugin.getPluginConfig()), "duplicate interaction debounced without bridge");
        check(!(boolean) limiter.invoke(listener, player, partner, plugin.getPluginConfig()), "different block accepted");
    }

    private void restrictions(AxiomPaper axiom, World world) {
        Player builder = rankPlayer("builder", world);
        check(axiom.getDataFolder().toPath().resolve("config.yml").toFile().exists(), "Axiom data-folder alias resolves");
        check(axiom.configuration.getInt("block-buffer-rate-limit") == 2, "Axiom reads managed rate limit");
        check(axiom.canModifyWorld(builder, world), "Axiom overworld allowed");
        for (World other : Bukkit.getWorlds()) {
            if (!other.equals(world)) check(!axiom.canModifyWorld(builder, other), "Axiom dimension denied " + other.getName());
        }
        for (String name : axiom.configuration.getStringList("disallowed-blocks")) {
            var block = BuiltInRegistries.BLOCK.getValue(Identifier.parse(name));
            check(block != null && block != Blocks.AIR, "valid disallowed block " + name);
            for (var state : block.getStateDefinition().getPossibleStates()) {
                check(axiom.allowedBlockRegistry.getId(state) == -1, "Axiom disallows " + state);
            }
        }
        check(axiom.allowedBlockRegistry.getId(Blocks.STONE.defaultBlockState()) >= 0, "Axiom allows ordinary building blocks");
    }

    private void enchantments(World world) {
        var plugin = (CrazyEnchantments) Bukkit.getPluginManager().getPlugin("CrazyEnchantments");
        var manager = plugin.getStarter().getCrazyManager();
        // Disabled enchants remain registered for reading existing item lore.
        // Gameplay and shop selection consult the activation flag instead.
        var names = manager.getRegisteredEnchantments().stream().filter(enchant -> enchant.isActivated())
                .map(enchant -> enchant.getName()).toList();
        check(!names.isEmpty(), "CE registers enchantments");
        check(names.stream().noneMatch(name -> name.equalsIgnoreCase("VeinMiner") || name.equalsIgnoreCase("Blast")), "CE mining duplicates disabled");
        check(names.stream().noneMatch(name -> name.equalsIgnoreCase("TreeFeller")), "CE TreeFeller duplicate disabled");
        check(manager.getPlayerMaxEnchantments(rankPlayer("default", world)) == 3, "CE default limit is three");
    }

    @Override public void onEnable() {
        Bukkit.getScheduler().runTaskAsynchronously(this, () -> {
            try {
                expectations = json("expectations.json");
                seedPermissions();
                Bukkit.getScheduler().runTask(this, () -> {
                    try {
                        for (String name : List.of("DoubleDoors", "AxiomPaper", "CrazyEnchantments", "TreeFeller", "FastAsyncWorldEdit", "Veinminer", "Vault")) {
                            check(Bukkit.getPluginManager().isPluginEnabled(name), name + " enabled");
                        }
                        check(Bukkit.getVersion().contains("159"), "pinned Paper build 159");
                        World world = Bukkit.getWorld("world");
                        AxiomPaper axiom = (AxiomPaper) Bukkit.getPluginManager().getPlugin("AxiomPaper");
                        permissions(axiom, world);
                        restrictions(axiom, world);
                        doors(world);
                        enchantments(world);
                        getLogger().info("ADDITIONS_PROBE_PASS");
                    } catch (Throwable failure) {
                        getLogger().severe("ADDITIONS_PROBE_FAIL");
                        failure.printStackTrace();
                    } finally {
                        Bukkit.getScheduler().runTask(this, Bukkit::shutdown);
                    }
                });
            } catch (Throwable failure) {
                getLogger().severe("ADDITIONS_PROBE_FAIL");
                failure.printStackTrace();
                Bukkit.getScheduler().runTask(this, Bukkit::shutdown);
            }
        });
    }
}

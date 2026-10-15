# Minecraft survival on link

Dawarich now uses `https://dawarich.finnrut.is`. Update the location-upload
app's server URL to that hostname. `map.finnrut.is` is reserved for BlueMap;
there is no redirect from that name to Dawarich and no data migration.

## Installed set and compatibility

Verified on 2026-10-09; TAB separately on 2026-10-10. Every release JAR uses
an exact URL and SHA-256 in `minecraft-plugin-artifacts.nix`; downloads were hashed before pinning. No
installed plugin JAR is updated at runtime. Configurations use Nix formats.
[Veinminer 2.12.3](games-veinminer.md) is an accepted exception for network
checks: it downloads updates into its data folder without installing them.

Geyser was rechecked on 2026-10-15 after Bedrock players reached the proxy but
Paper rejected them with `Outdated client! Please use 26.3`. Velocity now pins
[Geyser 2.12.0 build 1256](https://download.geysermc.org/v2/projects/geyser/versions/2.12.0/builds/1256),
published 2026-10-14 at 22:26:30 UTC, with Velocity SHA-256
`15b2bf8e025a46949a02bc3f6829667faa14938e8b6dbf09fc638ba1cfd3aae3`.
Its commit is `fc2170c97e088f910ba52e519ae3180e068af333`:
the [Java dependency targets 26.3](https://github.com/GeyserMC/Geyser/blob/fc2170c97e088f910ba52e519ae3180e068af333/gradle/libs.versions.toml),
and the [supported Bedrock list](https://github.com/GeyserMC/Geyser/blob/fc2170c97e088f910ba52e519ae3180e068af333/core/src/main/java/org/geysermc/geyser/network/bedrock/GameProtocol.java)
explicitly includes `26.52` (the reported iOS Bedrock 1.26.52 client) under
protocol `2193`.

The declarative Geyser YAML uses config version **10**, matching the pinned
[schema constant](https://github.com/GeyserMC/Geyser/blob/fc2170c97e088f910ba52e519ae3180e068af333/core/src/main/java/org/geysermc/geyser/Constants.java)
and [configuration interface](https://github.com/GeyserMC/Geyser/blob/fc2170c97e088f910ba52e519ae3180e068af333/core/src/main/java/org/geysermc/geyser/configuration/GeyserConfig.java).
The listener remains RakNet on UDP 19132 with Floodgate authentication and the
existing key path. The obsolete `bedrock.signaling.mode: none` override is
removed: valid modes are `builtin`, `nxs` and `hybrid`, and signaling is unused
with RakNet. New `advanced.nxs` options retain upstream defaults; no NXS keys
are overridden. Declaring the current schema avoids a startup version migration;
the remaining configured keys are present in that interface.

Floodgate stays at **2.2.5 build 141**, published 2026-09-17. The
[latest published build API](https://download.geysermc.org/v2/projects/floodgate/versions/latest/builds/latest)
still resolves to b141 with the already pinned Velocity SHA-256
`649835022de37ff09255fc626d4bfe7bc2a3b926d07b0dfaf1f51e12bf37001d`.
There is no newer published build to select. Upstream's newer
[26.3 source update](https://github.com/GeyserMC/Floodgate/commit/81b65ccb766bf8024858ebf3eefa6974056aecc5)
is not published as a newer build; it changes the command library dependency.
No Floodgate bump is required for Geyser 2.12.0's Java protocol translation.
This change does not deploy or establish a successful live Bedrock login.

| Plugin              | Version / placement            | Evidence                                                                                                                                                                                                                                   |
| ------------------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| SkinsRestorer       | 15.12.6 / Velocity and Paper   | [26.3 fixes](https://github.com/SkinsRestorer/SkinsRestorer/releases/tag/15.12.6); [release source targets Velocity 4.2.0](https://github.com/SkinsRestorer/SkinsRestorer/blob/15.12.6/gradle/libs.versions.toml)                          |
| MiniMOTD            | 2.2.5 / Velocity               | [Release](https://github.com/jpenilla/MiniMOTD/releases/tag/v2.2.5); [source](https://github.com/jpenilla/MiniMOTD/tree/v2.2.5/platform/velocity) ping, command and favicon calls inspected against the pinned Velocity 4.2.0 build 30 API |
| TAB                 | 6.2.0 / Paper                  | [Release explicitly adds Bukkit 26.3](https://github.com/NEZNAMY/TAB/releases/tag/6.2.0); pinned universal JAR descriptor, 26.3 version bound and native Paper implementation inspected                                                    |
| BlueMap             | 5.28 / Paper                   | [Explicit Paper 26.3 support](https://github.com/BlueMap-Minecraft/BlueMap/releases/tag/v5.28)                                                                                                                                             |
| LuckPerms           | 5.5.71 / Velocity and Paper    | [Paper 26.3 release](https://modrinth.com/plugin/luckperms/version/v5.5.71-bukkit), [Velocity release](https://modrinth.com/plugin/luckperms/version/v5.5.71-velocity); Finn explicitly approved Velocity compatibility                    |
| Simple Voice Chat   | bukkit-2.6.24 / Paper          | [26.3 release](https://hangar.papermc.io/henkelmax/SimpleVoiceChat/versions/bukkit-2.6.24)                                                                                                                                                 |
| TickScope           | 2.0.1 / Paper                  | [Maintained release](https://github.com/gzimbric/TickScope/releases/tag/v2.0.1), [26.3 compatibility](https://hangar.papermc.io/gzimbric/TickScope/versions/2.0.1)                                                                         |
| DiscordSRV classic  | 1.30.5 / Paper                 | [26.3 release](https://modrinth.com/plugin/discordsrv/version/1.30.5)                                                                                                                                                                      |
| Vault               | 1.7.3 / Paper (rank sync only) | [Pinned release](https://github.com/MilkBowl/Vault/releases/tag/1.7.3); isolated Paper 26.3 build 159 startup and DiscordSRV's LuckPerms provider lookup passed                                                                            |
| HuskHomes           | 4.11-9ed80cc **alpha** / Paper | [Pinned release metadata](https://api.modrinth.com/v2/version/eXHdkjXf) explicitly lists Paper and 26.3; [source commit](https://github.com/WiIIiam278/HuskHomes/commit/9ed80cc)                                                           |
| AxGraves            | 1.32.1 / Paper                 | [Release supports 1.20.2–26.3](https://hangar.papermc.io/Artillex-Studios/AxGraves/versions/1.32.1), published September 26, 2026                                                                                                          |
| Double Doors Server | 1.4.9 / Paper (Bukkit jar)     | [September 18 release supports 26.3](https://modrinth.com/plugin/double-doors-server/version/HhnvErM4); shaded Bukkit artifact avoids Paper's runtime SQL-library downloads                                                                |
| AxiomPaper          | 6.0.1+26.3 / Paper             | [Pinned MIT server component](https://modrinth.com/plugin/axiom-paper-plugin/version/V2yAy4up); descriptor targets API 26.3                                                                                                                |
| CrazyEnchantments   | 26.3-ed9d9ab **beta** / Paper  | [October 14 beta supports 26.3](https://modrinth.com/plugin/crazyenchantments/version/lIRmXa3P); stable 2.8.1 only lists 26.2                                                                                                              |

HuskHomes' stable 4.11 declares support through 26.2. The pinned September 23
Paper alpha explicitly declares 26.3, so it is used with Finn's approval of a
compatible prerelease. Its descriptor has `api-version: 1.20`; the release's
26.3 metadata is the compatibility evidence. HuskHomes supplies homes and TPA
together: SimpleHome and SimpleTPA are unnecessary and are not installed.

AxGraves is the preferred lightweight option for this friends server: indefinite,
owner-protected graves and XP storage need few settings. Alternatives are
actively maintained too: [GravesX 2026.4.9.2](https://modrinth.com/plugin/gravesx/version/2026.4.9.2)
declares 26.3, while [AngelChest Free 14.0.0-RC5](https://www.spigotmc.org/resources/angelchest-free.60383/)
lists 26.3 as a release candidate. Neither provides a clear maintenance advantage
over AxGraves' recent stable release for this scope.

MiniMOTD compatibility is a source/API assessment, not a claim of a live 4.2
integration test. Its dependencies target the older API, but the calls used
remain present in build 30. Velocity's native MOTD contains the same text as a
fallback if the plugin must be removed. Both use `Finn's Survival` on line 1
and `mc.finnrut.is · survival · 26.3` on line 2 (15 and 31 visible characters).
The bold name uses Mocha mauve `#cba6f7`, pink `#f5c2e7`, and peach `#fab387`;
the factual second line uses subtext0 `#a6adc8` with a mauve hostname. These
exact colours come from the Stylix Mocha scheme selected in
`modules/theme/color-scheme.nix` and the pinned Mocha Foot palette selected in
`modules/shell/terminal/foot.nix`.

The source headshot favicon from Finn's blog is committed as
`modules/games/assets/survival-icon-source.png` (180×180). Nix generates the
server icon with ImageMagick: box-filter downsampling to 24×24, four levels per
channel, a quality-18 JPEG round-trip with 4:2:0 chroma subsampling, then
nearest-neighbour enlargement to a 64×64 PNG24. The deliberately crunchy
result is built rather than committed, with no dependency on the blog checkout.
Velocity symlinks the same output to MiniMOTD's `icons/survival.png` and its
native `server-icon.png`; MiniMOTD enables icons and selects `survival`.
Both the MOTD and icon remain available while Paper is stopped because Velocity
answers server-list pings. The native icon remains the fallback if MiniMOTD
is removed.

SkinsRestorer uses file storage and Paper proxy detection `AUTO`; backend API
calls requiring database storage are disabled. Both installations have the
upstream `noautoupdate.txt` sentinel. Skin lookups still use normal upstream
skin services; this is separate from downloading plugin code.

Custom `minecraft.plugins` names cannot replace managed JAR names. A Paper
version change requires a new compatibility review and matching asset pins.

## Paired doors, Axiom and custom enchantments

All three JARs are immutable fixed-output Nix downloads. Their data folders are
included in clean-stop backups and the plugin inventory. Adding them does not
change the service's credential gates or apply LuckPerms changes to its database.

**Double Doors 1.4.9:** everyone explicitly receives `doubledoors.use` and
`doubledoors.toggle`; `/dd toggle` controls personal participation. Mirrored
doors open together through ordinary block-state updates on Java and Bedrock.
`enableRecursiveOpening` is enabled: in 1.4.9 this switch also gates ordinary
paired-door clicks. Fence gates and trapdoors are disabled separately; wooden
door clicks use the partner search rather than the connected-block search. Auto-close,
knocking, particles, SQL, anonymous tracking and update checks are disabled.

There is no backend Geyser/Floodgate installation. The pinned
[interaction listener](https://github.com/SzaBee13/double-doors-server/blob/v1.4.9/bukkit/src/main/java-common/me/szabee/doubledoors/bukkit/listeners/DoorInteractListener.java)
calls its duplicate guard without checking bridge availability. It tracks the
player UUID, world UUID and block position using monotonic time, suppressing
duplicates within 80 ms and retaining the configured 250 ms cooldown. Local
bridge detection and optional shared-SQL proxy heartbeats are separate from
that guard. Neither a Double Doors proxy companion nor Floodgate data forwarding
is needed for the debounce in this single-backend setup. Disposable Paper tests
exercise pairing and the guard with neither bridge installed; this does not
establish a live Bedrock-client interaction test.

**Axiom:** Java builders need the **Fabric client mod Axiom 6.1.3 for 26.3** plus
**Fabric API**. Bedrock cannot use its editor. Multiplayer use requires an
**Axiom commercial license or a whitelist request on the Axiom Discord**;
Finn will arrange that himself. The server plugin's MIT license does not grant
the client mod's commercial-use entitlement. See the
[official licensing instructions](https://axiomdocs.moulberry.com/other/commerciallicense.html).

Only builder has the explicit grants `axiom.use`, `axiom.editor.*`,
`axiom.build.*`, `axiom.tool.*`, `axiom.builder_tool.*`, `axiom.chunk.*`,
`axiom.can_import_blocks` and `axiom.can_export_blocks`. Mod inherits builder.
Builder explicitly denies world time/properties, player teleport/movement bypass,
infinite reach/no-clip/phantom/fast-place, entity editing, dangerous block ticking
and Axiom gamemode controls. No `axiom.default` grant is used. Admin retains `*`:
Axiom's `axiom.all` grants all its capabilities internally, even where a raw
LuckPerms query sees an inherited specific denial. Existing vanilla gamemode
permissions remain independent of Axiom's controls.

The managed `plugins/Axiom/config.yml` permits only `^world$`, the Survival
overworld, excluding `world_nether`, `world_the_end` and other world names.
The descriptor names its data folder `AxiomPaper`; a declarative directory link
from `plugins/AxiomPaper` to `plugins/Axiom` ensures the plugin consumes this
configuration and all of its persistent data is backed up. Disallowed placement
includes bedrock, barriers, all command blocks, structure blocks/void, jigsaws,
spawners/trial spawners, portal frames/blocks, gateways, light, reinforced
deepslate, moving-piston/head and test blocks. These are placement restrictions,
not a claim that existing blocks are protected from all editing tools.

Blueprint sharing, annotations, large chunk-data requests, enlarged payloads and
cross-world view teleporting are disabled. The block buffer allows **2 chunk
sections per second** (each section contains 4096 blocks), with at most **2 chunk
sends and 2 relights per tick** and edit-data loading limited to render distance.
The complete pinned configuration defaults are preserved. This server jar has no
update-check implementation or corresponding configuration switch.

No Velocity forwarding option or proxy Axiom plugin is required. The pinned
Velocity **4.2.0 build 30** bytecode forwards unregistered channels in both play
handlers; registration messages pass through too. The upstream
[client handler](https://github.com/PaperMC/Velocity/blob/dev/3.0.0/proxy/src/main/java/com/velocitypowered/proxy/connection/client/ClientPlaySessionHandler.java)
and [backend handler](https://github.com/PaperMC/Velocity/blob/dev/3.0.0/proxy/src/main/java/com/velocitypowered/proxy/connection/backend/BackendPlaySessionHandler.java)
show that path; the games plugin check inspects those same branches in the pinned
jar. Axiom registers namespaced channels such as `axiom:hello`, `axiom:enable`,
`axiom:response_chunk_data` and `axiom:tunnel`; these are client/backend traffic,
not the proxy's BungeeCord channel. This evidence does not substitute for a live
Fabric client handshake after a separately authorized deployment.

**Axiom edits do not enter FAWE's undo history.** There is no installed block
logger or rollback system: CoreProtect/Prism remain deferred. Backups are the
only server-side undo/recovery for these edits, requiring whole-world recovery
rather than a per-player rollback. FAWE's change limits do not constrain Axiom.

**CrazyEnchantments:** the October 14 `26.3-ed9d9ab` build is a deliberately
pinned **beta**, MIT-licensed with no hard dependencies. Everyone receives
`crazyenchantments.player.*`: GUI, tinker, blacksmith, GKitz, limit and information
access. Vanilla enchanting-table interaction remains unchanged; use `/ce` for
the separate custom-enchant GUI. Unsafe enchantment levels are disabled and the
default custom-enchant limit remains **3**. Bedrock sees custom enchants as
**plain item lore**, without Java-specific UI presentation.

Vault has no economy provider here; its existing permission hook serves rank
sync only. Vault-priced scramblers, slot/protection crystals, transmog/black/white
scrolls, success/destroy dust and lost-book shop entries have `InGUI: false`.
XP-priced enchant-book categories, the XP-priced blacksmith and tinker/info
remain available. No economy dependency or currency conversion is added.

Disabled enchants are **VeinMiner** (duplicates connected ore mining) and
**Blast** (adds another multi-block mining handler alongside the existing
Veinminer). **TreeFeller stays enabled**: existing Veinminer groups cover ores
and decorative stone, not logs. Other release defaults remain intact. CE metrics
are disabled; this pinned jar contains no update checker to enable or disable.

Axiom's chunk buffers, queued changes and native Zstandard compression make bulk
edits the main added resource concern. CE's armor processor can use 1–10 worker
threads with a bounded 10,000-item queue, scheduling work when players move
between block positions; some enchants also create entities. Paper retains
`-Xmx4G` and `MemoryMax=6G`, against
the previously measured **5.23 GiB** peak; the remaining margin is about 0.77 GiB.
Disposable startup measurements are not a multiplayer capacity guarantee.
After a separately authorized activation, use the existing memory/TPS panels
and bounded builder edits to assess headroom before increasing throughput.

The generated LuckPerms bootstrap and additive `chat-inventory.commands` include
these grants/denials. Existing databases need the documented operator application
and sync procedure after deployment; this change runs no live permission commands.

## Player list and community invite

TAB 6.2.0 runs only on Paper, alongside LuckPerms and CarbonChat. The single
Survival backend needs no proxy copy or bridge. TAB reads LuckPerms, player
counts, ping and Paper TPS/MSPT directly; PlaceholderAPI 2.12.3 exposes
FlectonePulse AFK state. Both TAB and PlaceholderAPI share the LuckPerms
readiness gate. PlaceholderAPI update checks and eCloud are disabled;
FlectonePulse registers its own expansion without downloading another JAR.
TAB starts and stops with the always-on backend; MiniMOTD handles its public
server-list entry through Velocity. TAB is omitted when the LuckPerms credential is absent.

The compact static header repeats MiniMOTD's bold mauve → pink → peach
`Finn's Survival` gradient, then `mc.finnrut.is` and online/configured maximum
players with the viewer's ping. The footer shows TPS/MSPT, the existing BlueMap
URL and `Discord: discord.gg/hHurpHK8RT`. Counts, ping and rank placeholders
refresh once a second; tick statistics refresh every five seconds. No rotating
tips, scoreboard, objectives, bossbars, layout, fake players, proxy support or
database are enabled. Backend bStats remains disabled. The inspected TAB JAR
has no update checker setting or runtime library downloads.

Names use the shared rank colour table in `minecraft-ranks.nix` and TAB's native
`%luckperms-prefix%`. The rank icons and translation fallbacks used by CarbonChat
remain intact through TAB's component transport. Sorting uses
native primary-group weights descending (admin → mod → builder → default),
then player names alphabetically ignoring case. LuckPerms calculates primary
groups with `parents-by-weight` on both platforms. Numeric sorting requires
TAB teams: they have empty nametag prefixes and an AFK-only suffix, retaining
collisions and ordinary invisibility. CarbonChat and the
configured FlectonePulse features do not manage those teams. Future plugins
that assign scoreboard teams need a compatibility review.

FlectonePulse 1.14.0 is the sole AFK system. Everyone can toggle `/afk`; five
minutes (6000 ticks) of positional inactivity automatically marks a player AFK.
That delay tolerates brief reading/inventory pauses. Position changes clear
AFK on the next one-second poll (`radius: 0.0`); chat and other commands also
clear AFK. Native detection does not treat looking around or inventory activity
as movement, and stationary chatting before AFK does not reset its idle timer.
There is no kick or exemption from Minecraft's sleeping/player-count rules.

TAB's `%condition:afk%` checks `%flectonepulse_setting_afk_suffix%=AFK` every
second. An unavailable expansion gives an empty marker. AFK players keep their
rank/name colours and gain a muted ` AFK` suffix in the Java player list and
overhead nametags. Chat announces `· Finn is now AFK` / `· Finn is no longer AFK`
with mauve names and muted text; the player sees the corresponding `You` message.
FlectonePulse's own chat, tab rendering and scoreboard remain disabled.

Carbon keeps its MiniPlaceholders/LuckPerms formats. Managed ranks explicitly
deny `carbon.chatplaceholders`, including wildcard admins, so adding
PlaceholderAPI does not reinterpret literal player chat. The backend needs a
restart after deployment to load the new plugin and reconcile datapacks.

Bedrock gracefully keeps its native player list. The pinned Geyser 2.12.0 build
1256 does not translate Java list display names, sorting or header/footer;
the Java formatting cannot be promised there. The Discord invite remains
available in first-join chat, DiscordSRV's existing `/discord` command when the
bridge is installed, and the games dashboard's Connect section beside Map.
Bedrock players use the same UUID-based AFK state and receive the chat
announcements. Geyser translates the team suffix for overhead nametags; confirm
client appearance during the approved activation gate. No Bedrock-only plugin
or backend Floodgate installation is added.

The public invite is declared once as
`gameServers.servers.survival.minecraft.discord.inviteUrl`, independently of
DiscordSRV's token and channel readiness. TAB, first-join welcome,
DiscordSRV `DiscordInviteLink` and dashboard metadata reference that value.
Other servers default to an empty invite; empty values omit invite lines and
links. The targeted checks cover that case, replacement invites and capacity,
absent credentials, additional backends, TAB's pinned YAML/MiniMessage parsers,
native LuckPerms prefix/weight hooks and dashboard rendering.

## Pregeneration and borders

[Chunksmith 4.6.0+26.x-plugin](https://modrinth.com/plugin/chunksmith/version/MsSa6z1v)
replaces Chunky on Paper 26.3. Kishku7's open-source Chunky fork credits pop4959
and contributors; Modrinth lists GPL-3.0-only, while the
[source headers](https://github.com/Kishku7/Chunksmith/blob/6c4f57d324f449a6c32329ab9382af9b3028b2e5/Plugin/shared_plugin/bukkit/src/main/java/com/kishku7/chunksmith/ChunksmithBukkit.java)
say GPL-3.0-or-later. The immutable October 13, 2026 release is pinned with
SHA-256 `sha256-bc3MtDgRuzOZKUwsvuvEDC0WjgbosTRcvyJvlMr5uuo=`.
Its configuration and saved tasks use `plugins/Chunksmith`. The old
`plugins/Chunky` directory remains untouched and included in pre-change and
scheduled clean-stop backups. CSLOD files under each world's
`chunksmith/lod/<dimension>/` are covered by the existing world backups.
The pinned JAR has no runtime downloader/updater. Backend bStats stays disabled.

**Installation does not start generation.** Finn chose to reuse Chunky's
existing saved area, with possible expansion later. The agent could not read
the live `plugins/Chunky` directory as `tunnel`, so its actual bounds and whether
a selection exists still require operator verification. No selection is set
or imported, and no task, refresh or resume runs automatically. Both
`continue-on-restart=false` and
`lod-from-explored-chunks=false` are declared; the latter prevents the new 4.6
exploration hook from filling the store outside the saved area. Existing
terrain is retained, but installing the plugin alone does not create far LODs.

The old managed `plugins/chunky.jar` is removed by nix-minecraft's managed-file
cleanup at the next approved service start, and only `plugins/chunksmith.jar`
is declared. This avoids their shared `chunky`/`cy` aliases. Before that future
change, pause any old Chunky task, cleanly stop/save Paper, and ensure a verified
backup containing `plugins/Chunky` exists. The fingerprint change invokes the
existing pre-change snapshot guard when backups are enabled; if backups are
disabled or unavailable, take and verify an operator backup before proceeding.
No running server, state directory or backup is modified by building this change.

Do not rely on automatic migration: this release's startup migration code
checks `Chunksmith` as both the old and new directory name. Preserve the entire
legacy directory, including `tasks/*.properties` and any CSV selection input.
Before a future manual run, inspect those records read-only for `world`,
`center-x`, `center-z`, `radius`, optional `radius-z`, `shape`, `pattern` and
`csv`. Re-enter the approved selection using `cs` commands and inspect
`cs selection` before starting a fresh pass. Do not copy the old `config.yml`,
overwrite new task files, or resume old completed-chunk counters for LOD
backfill: they would skip terrain that has never had a CSLOD record. If there
is no saved selection, keep generation stopped until Finn supplies one.

**ChunkyBorder is deferred:** its published
[Paper 1.2.23 release](https://modrinth.com/plugin/chunkyborder/version/asaBBItO)
declares support through 26.2, with no verified 26.3 release on 2026-10-09.
Finn chose to wait for verified compatibility. No custom border is installed,
set, resized or enforced. Pregeneration alone does not limit exploration.

Survival runs continuously, including with no players connected. Chunksmith
tasks can continue through idle periods; no player or status ping is needed to
keep Paper running. Keep the clean-stop guard enabled for maintenance changes.

After verifying the saved area, Finn can enter its world, shape, center and radius
in the Survival dashboard console, verify `cs selection`, then use `cs start`
and `cs progress`. Do not run these generation commands until the saved bounds
are verified. A task selection bounds that pass; it does not enforce a world border
or stop ordinary player exploration. There is no automatic schedule or LOD
horizon beyond the selection.

Use `cs pause` before a maintenance stop; use `cs continue` only after verifying
the approved task. Leaving the game no longer stops Paper. Choose other dimensions
explicitly rather than starting parallel tasks. Do not run `cs trim`: it deletes
terrain outside the selection. Finn's existing operator permissions cover
Chunksmith; friends do not receive generation/admin commands.

The declared generation controls use two concurrent dispatches, a 54 ms tick
target, a 5 ms generation budget, 30 ms player reserve and 60 ms ceiling;
queued writes are capped at 100, the LOD queue at 64, heap pressure at 75%, and
overload auto-pause uses a 30-second grace period. These are cooperative
controls, not a CPU quota or per-chunk deadline. Paper retains its 4 GiB maximum
heap and 6 GiB service limit. The 256 MiB `lod-index-budget-mb` limits one index
response's advertised data budget, not total disk usage or bytes per second.
There is no configurable global bandwidth or store-size cap; the HTTP server
has four workers, six concurrent requests per IP and a 30-second stalled-write
timeout. Monitor disk, tick time and outbound traffic before expanding an area.

BlueMap reads the saved Minecraft chunks afterwards; no Chunksmith addon is
needed for normal saved-chunk pregeneration. It renders with players online and
continues while the server is idle, using one low-priority thread. LOD-only no-save horizons
are not a source for BlueMap. Map configuration and existing resource budgets
remain as declared.

### Multiplayer LOD and player setup

Java players on 26.3 install **Distant Horizons 3.3.4** and the matching
**Chunksmith 4.6.0 client mod** for their loader:
[DH release](https://modrinth.com/mod/distanthorizons/version/TGgEbP9A),
[Fabric release Sun3j32A](https://modrinth.com/plugin/chunksmith/version/Sun3j32A),
[NeoForge release 7WsBTgKP](https://modrinth.com/plugin/chunksmith/version/7WsBTgKP).
These are player-side dependencies, not additional Paper or Velocity JARs.
Chunksmith server/client use CSLOD protocol 4 and the client feeds DH through
its API; this is not the native DH server protocol. Fabric also requires
Fabric Loader 0.18.1 or later and Fabric API; the 26.3 build requires Java 25.
Enable DH rendering, choose its desired LOD distance, and join the usual
`mc.finnrut.is` Minecraft address. Chunksmith detects DH automatically, requests
server LODs within that renderer distance and feeds them into DH. Use
`/csclient status` to inspect the detected renderer and download state.
Bedrock/Geyser players do not install these mods and continue using the normal
gameplay connection.

Survival advertises the direct **HTTP endpoint `mc.finnrut.is:25568`**, bound
to `0.0.0.0:25568`; the NixOS firewall opens TCP only. Velocity connects directly
to loopback Paper on 25567; survival has no lazymc listener on 25566. There is no `lod.finnrut.is`,
reverse proxy or HTTPS endpoint. The actual file path is
`/lod/<dimension>/r.<region-x>.<region-z>.cslod`, for example
`/lod/minecraft_overworld/r.0.0.cslod`. There is no unauthenticated directory
listing or root health endpoint. The client gets the index and its
`X-Chunksmith-Token` over the `chunksmith:lod` game plugin channel.

[The token implementation](https://github.com/Kishku7/Chunksmith/blob/6c4f57d324f449a6c32329ab9382af9b3028b2e5/shared_common/src/main/java/com/kishku7/chunksmith/lod/net/CsLodTokens.java)
binds each token to the online player, their Paper-visible IP and a ten-minute
expiry, and revokes it on disconnect. HTTP checks the socket peer IP and
ignores `X-Forwarded-For`; an HTTP proxy or different IPv4/IPv6 egress address
can therefore fail authentication. The existing DNS record is unproxied IPv4.
Velocity's modern forwarding should provide the real player IP; no additional
Velocity plugin is declared. **The token/IP binding and plugin-channel path
through Velocity still require a live client test after deployment.**
After a future manual backfill has produced at least one LOD region, test an
authenticated download through the usual game address, wrong/missing
token rejection, disconnect/reconnect, and a clean service restart. The HTTP
listener remains present while survival is idle, but valid download tokens
still require an online authenticated player. Test unmodified Java and Geyser joins too. Do not forward UDP 25568.

### Refreshing cached terrain

Chunksmith can rebuild stored LODs, but it does not automatically invalidate
them after edits. In 4.6.0,
[`ExploredLod.shouldTake`](https://github.com/Kishku7/Chunksmith/blob/6c4f57d324f449a6c32329ab9382af9b3028b2e5/shared_common/src/main/java/com/kishku7/chunksmith/lod/ExploredLod.java)
deliberately skips chunks already present in the store to keep the common
save/unload path cheap. There is no block-place/break invalidation hook, so
automatic cached-edit refresh remains a missing feature. The
[explored-terrain issue #46](https://github.com/Kishku7/mod_support/issues/46)
explains the 4.6 new-chunk capture feature; it does not resolve stale cached
terrain, and no supported automatic invalidation roadmap was found.

**Once the saved area is verified**, keep a player connected, select and inspect the
approved world/area, and use this operator procedure for initial backfill or
a maintenance refresh of an already-stored area:

```text
cs selection
cs set forceLoadExistingChunks true
cs start
cs progress
```

This must be a fresh pass, not a continuation of old completed progress.
[GenerationTask](https://github.com/Kishku7/Chunksmith/blob/6c4f57d324f449a6c32329ab9382af9b3028b2e5/shared_common/src/main/java/com/kishku7/chunksmith/GenerationTask.java)
uses the force flag to bypass both existing-chunk and existing-LOD skips, and
the store replaces each chunk's record with a new capture. The pass can
generate holes inside the selected area; it is not a strict "existing chunks
only" mode. Restrict the selection to Finn's approved pregenerated area.
Pause before anyone leaves. After completion, run
`cs set forceLoadExistingChunks false`; on an interrupted pass, restore false
while paused and set true again before explicitly continuing that refresh.
The declarative false value is restored at the next managed service start.
No scheduled refresh is installed, because console activity cannot keep
Paper running and installation leaves all tasks stopped.

Edits may stay stale indefinitely before this procedure. After a region is
rewritten, the server can notify connected, synchronized clients at roughly
one-minute intervals; the client also polls every five minutes by default.
Allow download and DH processing time beyond that, and verify the result on
a live client rather than promising an exact refresh delay. The region file's
freshness changes so the matching client can re-inject it. If it remains stale,
use `/csclient inject_dh` after the server rebuild: this supported 4.6 client
command resets its injection bookkeeping, requests the current index and
replays LODs into DH without reconnecting. Monitor `/csclient status`. It does
not recapture server terrain itself. Alternatively, use
`/csclient set reinject-on-join true`, reconnect, and restore it to false.
Do not delete the player's DH database. Store rewrites
append payloads and replace header entries without compacting old payloads;
repeated area rebuilds increase disk use. Take a clean backup and inspect disk
headroom before a substantial refresh.

## World datapacks and game rules

The separate dashboard **Datapacks** list shows the following installed set,
plus the generated Survival World Policy, Grave Compass and Survival Join Tips packs. Installation
status describes the declaration; it does not assert that Paper is awake or a
player's HUD is on.

| Vanilla Tweaks pack   | Pinned version | Minecraft / format |
| --------------------- | -------------- | ------------------ |
| Confetti Creepers     | 2.2.19         | 26.3 / 121.0       |
| Player Head Drops     | 1.1.18         | 26.3 / 121.0       |
| Mini Blocks           | 1.1.8          | 26.3 / 121.0       |
| More Mob Heads        | 2.20.1         | 26.3 / 121.0       |
| Custom Nether Portals | 2.3.21         | 26.3 / 121.0       |
| Double Shulker Shells | 1.3.18         | 26.3 / 121.0       |

AFK Display is retired in favor of FlectonePulse. Its owned
`infra-afk-display.zip` and ledger entry are removed on the next stopped-server
reconcile; the old AFK team requires the operator cleanup described below.

Coordinates HUD, Silence Mobs, Durability Ping and Armor Statues are no longer
managed. The stopped-server reconcile also removes their four previously
managed ZIPs and ledger entries, preserving unrelated datapacks and world data.
It does not run the removed packs' uninstall functions or erase persistent
scoreboards/items they created. Anti Enderman Grief remains absent: endermen
retain vanilla behavior. No second sleep/graves/home datapack is included.

**Official source and reproducibility:** Finn downloaded the official
[Vanilla Tweaks picker](https://vanillatweaks.net/picker/datapacks/) bundle
`VanillaTweaks_d326112_UNZIP_ME.zip` on October 9, 2026. Its SHA-256 is
`05f9f2a4256b4bf3a40e10b1a250959e6850e9ecf6ff55e68f6aebe0a0f53ce4`.
`modules/games/datapacks/sources.json` records that provenance and each inner
ZIP's original filename, canonical import filename, version and SHA-256.
All six retained packs declare `[121,0]` as both minimum and maximum format.
Their bytes and metadata are unchanged; the outer bundle is unwrapped before importing.

This public repository contains metadata and attribution only, with no
Vanilla Tweaks archive bytes. Each `pkgs.requireFile` input has a flat
SHA-256 hash and a canonical basename. Missing inputs fail the build with the
exact import command, rather than downloading anything. Neither runtime nor
build-time code contacts the pack builder. Future updates require obtaining
and reviewing new official files and hashes. Vanilla Tweaks attribution stays
in `credits.txt`. The packs remain subject to the
[Vanilla Tweaks terms](https://vanillatweaks.net/terms/); obtain them separately
from the official picker. Archives must not be committed here or added to
nix-secrets. The repository's unfree allowance covers only these six manual
inputs.

### PaperTweaks evaluation (2026-10-10)

**The original evaluation retained seven official Vanilla Tweaks packs and the
local Survival World Policy pack.** AFK Display has since been retired in favor
of FlectonePulse; the six remaining packs and World Policy are retained.
PaperTweaks is maintained and now publishes 26.3 metadata, but does not cover
this installed set. No PaperTweaks JAR or permissions are added,
and no datapacks or world state are removed by this evaluation. The inventory
above is the current repository declaration; this audit did not inspect the live
server or enumerate unmanaged packs there. At evaluation time, all seven
official ZIPs in the local Nix store were inspected and matched the then-current
SHA-256 values in `sources.json`.

The latest release in the
[Modrinth API](https://api.modrinth.com/v2/project/papertweaks/version) is
[PaperTweaks 0.7.3](https://api.modrinth.com/v2/version/2zcgGHsV), published
October 9, 2026, for Paper/Purpur, explicitly including Minecraft 26.3.
[Hangar](https://hangar.papermc.io/Machine_Maker/PaperTweaks/versions) and
[GitHub Releases](https://github.com/MC-Machinations/PaperTweaks/releases/tag/v0.5.0)
still show 0.5.0 (January 1, 2025; Paper 1.21.4); those listings alone give an
outdated impression of compatibility and maintenance. Current source commit
[`b6e68bd1`](https://github.com/MC-Machinations/PaperTweaks/commit/b6e68bd1c3009d136ec0fc460486af567550bf90)
declares 0.7.3, targets the 26.3 Paper API and Java 25, and has a
[successful CI run](https://github.com/MC-Machinations/PaperTweaks/actions/runs/37870079882).
The 26.3 update merged October 8, followed by fixes October 9. The survival
backend resolves to **Paper 26.3 build 159** under this repository's lock.
Release metadata and source targeting support that version family; this audit
does not establish a successful PaperTweaks startup on build 159.

The published Modrinth JAR was inspected in memory and matched its API SHA-512.
Its `paper-plugin.yml` reports **0.7.0-SNAPSHOT**, despite the published 0.7.3
label. Any future integration must distinguish that internal version from the
artifact pin in inventory tests. The JAR contains the four matching modules
below and the MoreMobHeads deprecation warning, with no Mini Blocks or Double
Shulker Shells module classes.

| Current pack / behavior                                                          | PaperTweaks module and enablement key                    | Coverage                                                                                                                                                                                |
| -------------------------------------------------------------------------------- | -------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Confetti Creepers: default 100% confetti; sets explosion radius to zero          | `ConfettiCreepers` / `experimental.confetti-creepers`    | Similar outcome; plugin cancels the explosion and replaces the creeper with a firework. Firework damage and charged-creeper settings need comparison.                                   |
| Player Head Drops: head drops on PvP kills                                       | `PlayerHeadDrops` / `items.player-head-drops`            | Supports player-kill requirement and drop chance.                                                                                                                                       |
| Mini Blocks: 209 stonecutter recipes producing textured heads                    | None                                                     | `WanderingTrades` / `hermitcraft.wandering-trades` adds trader offers, not these recipes or their acquisition mechanics.                                                                |
| More Mob Heads: mob-specific head loot and conditions                            | `MoreMobHeads` / `mobs.more-mob-heads`                   | Deprecated; the module explicitly recommends the official datapack for improved functionality without a performance hit.                                                                |
| Custom Nether Portals: nonrectangular/crying-obsidian frames; 10–84 frame blocks | `CustomNetherPortals` / `survival.custom-nether-portals` | Supports custom shapes/materials, but config limits portal interior size, width and height rather than the pack's frame-block count.                                                    |
| Double Shulker Shells: two shells per shulker, alongside head loot               | None                                                     | Retain the loot-table datapack; an old wiki module listing does not establish current support.                                                                                          |
| Retired AFK Display: superseded by FlectonePulse                                 | `AFKDisplay` / `survival.afk-display`                    | Plugin defaults to 300 seconds, checks block-position inactivity each second, colors display/tab names directly, and clears AFK on a player-move event. Timing and presentation differ. |
| Survival World Policy: reapplies 50% sleeping on world load                      | Local pack                                               | Retain; do not enable a second sleep implementation.                                                                                                                                    |

Module names, configuration keys and behavior above are from the
[reviewed source tree](https://github.com/MC-Machinations/PaperTweaks/tree/b6e68bd1c3009d136ec0fc460486af567550bf90/src/main/java/me/machinemaker/papertweaks/modules).
In particular,
[MoreMobHeads' lifecycle](https://github.com/MC-Machinations/PaperTweaks/blob/b6e68bd1c3009d136ec0fc460486af567550bf90/src/main/java/me/machinemaker/papertweaks/modules/mobs/moremobheads/Lifecycle.java)
asks operators to disable that module in favor of Vanilla Tweaks. Thus even
a verified 26.3 release cannot replace all six retained packs. Keeping the
current set preserves recipes, drops and gameplay. The AFKDisplay module must
remain disabled because FlectonePulse owns AFK.
A partial switch of the three matching retained modules is a possible future task,
requiring explicit behavior choices and client/startup validation; this audit
does not perform that switch.

**Declarative configuration and permissions:** PaperTweaks reads enablement
booleans from `plugins/PaperTweaks/modules.yml` (all modules default disabled)
and module settings from
`plugins/PaperTweaks/modules/<lowercase-module-name>/config.yml`. Global settings
live in `plugins/PaperTweaks/config.yml`. YAML files suffice for configuration;
the GUI and commands are optional. A future Nix integration should use the
existing writable configuration templates, preserving the plugin's state
directory in backups. GUI/command changes write files and would be overwritten
by the next declarative preparation. See the source
[module registry](https://github.com/MC-Machinations/PaperTweaks/blob/b6e68bd1c3009d136ec0fc460486af567550bf90/src/main/java/me/machinemaker/papertweaks/modules/ModuleRegistry.java)
and [config binding](https://github.com/MC-Machinations/PaperTweaks/blob/b6e68bd1c3009d136ec0fc460486af567550bf90/src/main/java/me/machinemaker/papertweaks/modules/ConfigModule.java).

Permissions retain the `vanillatweaks.*` prefix. A future partial integration
must grant default players `vanillatweaks.playerheaddrops`, plus public
information commands only where needed; the three matching retained modules
have no equivalent player-toggle commands
to add. Confetti and portal mechanics themselves have no player permission
gate. Restrict `vanillatweaks.main.enable`, `.disable`, `.reload`, and module
`*.admin.config` permissions to the LuckPerms admin group, including denying
those nodes for default/mod if necessary to override Bukkit's operator
defaults. Do not grant the broad `vanillatweaks.*` wildcard to players or mods.
The datapack's `/trigger cusNetPor` is a public information display, whereas
its global `/function ...:config` actions require operator authority. Preserve
that separation in any replacement. The
[plugin permission declarations](https://github.com/MC-Machinations/PaperTweaks/blob/b6e68bd1c3009d136ec0fc460486af567550bf90/src/main/resources/paper-plugin.yml)
and `minecraft-permissions.nix` are the sources for a future permissions change.

### State left by a future datapack removal

Removing the retained packs' ZIPs alone would stop
loading their functions, recipes and loot tables but would not uninstall the
state they created. The current reconciler only removes ledger-owned archive
bytes; it never edits scoreboards, entities, items, advancements or world NBT.
The following inventory comes from the exact pinned official ZIPs, including
the retired AFK Display pack:

| Pack                  | State that can survive removal                                                                                                                                                                                                                                                                                                                                                                    |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Confetti Creepers     | Objectives `cftCreep` and `cftCreep.config` with player/fake-player scores; scheduled `tick`, `check_trigger`, `give_effects`, and temporary `restore_command_feedback` functions under `confetti_creepers:`. Existing entities can retain `cftCreep.done` / `cftCreep.confetti` tags; selected creepers retain `ExplosionRadius:0` and the long Luck effect.                                     |
| Player Head Drops     | Generated head items and placed heads/profiles. No pack-created scoreboard objectives, scheduled functions or command storage were found.                                                                                                                                                                                                                                                         |
| Mini Blocks           | Crafted miniature head items and placed heads/profiles. No pack-created scoreboard objectives, scheduled functions or command storage were found.                                                                                                                                                                                                                                                 |
| More Mob Heads        | Dropped head items and placed heads/profiles. No pack-created scoreboard objectives, scheduled functions or command storage were found.                                                                                                                                                                                                                                                           |
| Custom Nether Portals | Objectives `cusNetPor`, `cusNetPor.config`, `cusNetPor.dummy` with player/fake-player scores; scheduled `try_to_trigger`, `enable_trigger`, and temporary `restore_command_feedback` functions under `custom_nether_portals:`. Player advancement progress for `custom_nether_portals:use_ignition` and created portal blocks may remain; `cusNetPor.marker` clouds are temporary (`Duration:0`). |
| Double Shulker Shells | Previously dropped shells. No pack-created scoreboard objectives, scheduled functions or command storage were found. Shared vanilla loot random-sequence state must not be purged.                                                                                                                                                                                                                |
| AFK Display           | Objectives `afkDis.x1`, `afkDis.x2`, `afkDis.y1`, `afkDis.y2`, `afkDis.z1`, `afkDis.z2`, `afkDis.checkAFK`; team `afkDis.afk` and its membership; scheduled `afk_display:second`. Team membership can leave names gray after removal; prior team membership was overwritten and cannot be reconstructed automatically.                                                                            |
| Survival World Policy | Sleeping percentage persists in `level.dat`; removing this pack would stop reapplying it. Retain this local pack.                                                                                                                                                                                                                                                                                 |

The supplied `confetti_creepers:uninstall`, `custom_nether_portals:uninstall`
and `afk_display:uninstall` functions remove their objectives and main scheduled
loops; AFK's uninstall also removes its team. They are not comprehensive
migration tools: the first two omit the temporary feedback-restoration schedule,
and none restores modified creepers, portal blocks or previous team memberships.
Removing a pack can leave scheduled references to unavailable functions;
inspect them during any future migration rather than deleting world files.

Any future removal needs a verified clean-stop snapshot, inspection of existing
objectives/team membership and a separately reviewed operator cleanup step.
If invoking the pack's uninstall function, it must still be installed and
enabled in an isolated maintenance session; clear any remaining named schedules
and check the command-feedback gamerule before disabling/removing the pack.
Do not remove shared objectives or storage by prefix, delete entity/player data,
or reset creeper properties automatically. Inert namespaced objectives can be
retained for rollback, while a stale AFK team needs deliberate review to avoid
persisting gray names. Preserve existing items, heads and portals. Restart
normally after reconciling, using the existing pregeneration/datapack pipeline;
do not add live `/reload` migration hooks or bypass the prechange snapshot.

### AFK Display retirement at the approved activation gate

Source removal stops the old pack from loading on the next Paper start. The
installer removes only its ledger-owned, unmodified archive before startup;
it neither edits world NBT nor removes scoreboard state. A modified archive
fails preparation for operator review and is not silently discarded.

Before removing the old pack, the operator must take a verified clean-stop
snapshot and use an isolated maintenance session with the old pack still
installed and enabled. Run these exact console commands:

```console
function afk_display:uninstall
datapack disable "file/infra-afk-display.zip"
```

The inspected uninstall clears only `afk_display:second`, removes the seven
`afkDis` objectives listed above and removes team `afkDis.afk`. Disabling the
pack prevents its load function from recreating those objects. Confirm that
team and schedule are gone, then stop cleanly and activate the new configuration
through the existing prechange snapshot and datapack preparation pipeline.
Other packs stay enabled; do not remove shared objectives, region/player files
or other world state. Previous team memberships cannot be reconstructed.

Restart the Paper backend normally after deployment; do not use a live reload
as a migration hook. Confirm `/afk`, five-minute positional auto-AFK, movement
and chat clearing, Java list/overhead markers, and Bedrock chat/overhead names.
Bedrock's native player list has no AFK marker on the pinned Geyser build.
This repository change does not execute the cleanup, activation or deployment.

### Provisioning a builder

On each fresh machine or CI builder, obtain the exact official bundle and
verify its recorded SHA-256. Work outside the repository; unwrap it once with
`unzip VanillaTweaks_d326112_UNZIP_ME.zip`. Rename each inner ZIP without
recompressing it, then import it:

```console
mv 'confetti creepers v2.2.19 (MC 26.3).zip' confetti-creepers-2.2.19-mc26.3.zip
mv 'player head drops v1.1.18 (MC 26.3).zip' player-head-drops-1.1.18-mc26.3.zip
mv 'mini blocks v1.1.8 (MC 26.3).zip' mini-blocks-1.1.8-mc26.3.zip
mv 'more mob heads v2.20.1 (MC 26.3).zip' more-mob-heads-2.20.1-mc26.3.zip
mv 'custom nether portals v2.3.21 (MC 26.3).zip' custom-nether-portals-2.3.21-mc26.3.zip
mv 'double shulker shells v1.3.18 (MC 26.3).zip' double-shulker-shells-1.3.18-mc26.3.zip
nix-store --add-fixed sha256 ./confetti-creepers-2.2.19-mc26.3.zip
nix-store --add-fixed sha256 ./player-head-drops-1.1.18-mc26.3.zip
nix-store --add-fixed sha256 ./mini-blocks-1.1.8-mc26.3.zip
nix-store --add-fixed sha256 ./more-mob-heads-2.20.1-mc26.3.zip
nix-store --add-fixed sha256 ./custom-nether-portals-2.3.21-mc26.3.zip
nix-store --add-fixed sha256 ./double-shulker-shells-1.3.18-mc26.3.zip
```

`nix-store --add-fixed sha256` uses flat hashing without `--recursive` and
matches `requireFile`'s hash mode. Both bytes **and basename** must match; an
import under the original filename containing spaces is not the declared
input. `nix store add --mode flat --hash-algo sha256` is an alternative when
used with the same canonical filenames.

Imports alone are not GC roots. Before an installed system retains the inputs,
create a root for each returned store path, for example:

```console
mkdir -p .gcroots/vanillatweaks
nix-store --realise --add-root "$PWD/.gcroots/vanillatweaks/confetti-creepers" /nix/store/<returned-path>-confetti-creepers-2.2.19-mc26.3.zip
```

Repeat for all six retained packs, keeping that root directory at its original
path. This worktree's `.gcroots/` is ignored by git; deleting the worktree removes those
local roots. On link, `system.extraDependencies` retains all six selected ZIPs
in the installed system closure, rooted by the system profile and its retained
generations, even while Paper is stopped. Merely evaluating or building with
`--no-link` does not create that installed-profile root. A store that has lost
its roots and been garbage-collected needs the import step again. Provision
remote builders' stores too, or explicitly transfer the required closure to
them; these inputs are not automatically fetched from a public cache.

### Pack behavior and client caveats

Player Head Drops requires a player killer (PvP), not every death. More Mob
Heads and Double Shulker Shells use merged Vanilla Tweaks loot-table tags so
heads and two shells coexist.

Confetti Creepers produces cosmetic firework bursts, **and changes explosion
mechanics**: the supplied pack defaults to a 100% confetti chance and sets
selected creepers' explosion radius to zero, preventing block destruction.
It is not purely cosmetic. Mini Blocks 1.1.8 provides stonecutter recipes that
turn blocks into textured player heads; this bundle contains no wandering
trader trades. Custom Nether Portals changes vanilla portal mechanics by
enabling nonrectangular frames and crying obsidian by default (10–84 frame
blocks). The official archives and their upstream defaults are preserved.

None of the six retained packs requires an additional Java resource pack:
mini blocks and heads use vanilla player-head profiles, and confetti uses
vanilla fireworks.
Normal client skin-texture requests are separate from downloading pack code.
[Bedrock/Geyser custom-head limitations](https://geysermc.org/wiki/geyser/custom-skulls/)
apply to Mini Blocks, More Mob Heads and Player Head Drops: placed heads can
use Geyser's existing rendering, but correct inventory/held/worn textures
require explicit skull mappings and Geyser's generated Bedrock resource pack.
Those mappings are not added by this change. Verify native Bedrock names and
scoreboard/team interactions on Java and Geyser clients after the authorized
deployment. Paper smoke tests
cannot establish client presentation parity.

The installer writes stable `infra-*.zip` names into `world/datapacks/` as the
Minecraft unit user, after `games-prechange`, upstream server preparation and
`games-prepare`, before Paper starts. It copies archive bytes, so world
backups contain usable packs rather than symlinks into a particular Nix store.
The `.infra-managed.json` ledger also lives in that backed-up directory.
Reconciliation is idempotent and journals both old/new hashes so interrupted
updates can resume. It removes only previously managed archives, preserves
unrelated packs/world data, and refuses unowned filename collisions, manually
modified managed files or symlinked directories/files. Resolve such a collision
while stopped; do not delete unrelated datapacks to bypass it.

Pack additions, updates and removals participate in the same prechange
fingerprint as plugin JARs/configurations. The existing clean-stop proof and
snapshot must succeed before pack changes reach the world. Restore pack bytes
and their ledger with the world, and select matching declarations before the
next start; a different declaration reconciles after its prechange snapshot.

`spawn-protection=0` is generated in `server.properties`. The policy pack's
`minecraft:load` function executes
`gamerule minecraft:players_sleeping_percentage 50` (the current name for
`playersSleepingPercentage`) after the world loads on every Paper start and
`/reload`. Minecraft owns the resulting `level.dat` persistence; Nix never
patches NBT directly. A manual gamerule change is overridden on the next load.
The policy pack runs without a polling unit, extra wake or RCON credential.

### Private join guidance

Survival enables `gameServers.servers.survival.minecraft.joinTips.enable`;
other backends default to disabled. The managed `infra-join-tips.zip` datapack
sends returning players exactly two private chat lines: `· Welcome back, NAME!`
and one randomly chosen `· Tip: …` line. The name is the player's selector name,
not Carbon's nickname: datapacks have no cheap direct Carbon display-name hook.
Nobody else receives either line. Random choices are independent and can repeat.
There are no periodic tips or broadcast tips.

A genuine first join receives only this six-line Getting Started block:

```text
· Welcome to Finn's Survival! Quick start:
· Homes: /sethome <name>, then /home <name> (10 max)
· Friends: /tpa <player>, they reply /tpaccept
· Mine ores while sneaking to vein-mine them
· Death keeps items+XP in a grave; follow your Grave Compass
· Map: map.finnrut.is · Discord: /discord
```

FlectonePulse's existing public first-join announcement and Discord invite are
unchanged. Its greeting and periodic auto-message modules stay disabled.

The pack polls player join state each tick, before player ticks increment
`play_time`. A missing `ijt_leave` score triggers classification: the persistent
`infra.join_tips.seen` tag or a saved `minecraft:play_time` / `minecraft:leave_game`
statistic of at least one means returning. The predicate reads the player's
actual persisted statistics; a newly created statistic scoreboard does **not**
backfill history. Thus friends who played before installation get the returning
welcome and tip, without manually tagging UUIDs or editing player data. Historical
leave counts also recognize a prior session that ended before its first full tick.
The assumption is that ordinary saved player statistics have been retained.

After either path, the pack records its tag and consumes the leave counter.
`ijt_leave` uses `minecraft.custom:minecraft.leave_game`; a normal disconnect,
including a clean server shutdown, increments it for the next join. Load functions
only create objectives, retaining tags and scores across `/reload`. Death,
respawn, dimension changes and staying online do not send another tip. The random
choice is stored in `ijt_tip`; neither objective is displayed or changes TAB teams.
All message commands are `tellraw @s` inside the joining player's function context.

The text source is `lib/minecraft-join-tips.nix`: edit its `tips` list to change
advice, or `welcome` to change the six-line block. Numbered functions and the random
range are generated from the list length. Static functions and history predicates
live under `modules/games/datapacks/join-tips`. Nix builds the deterministic ZIP
through the same `packFiles`/installer path as Grave Compass. Map text and links
use the backend's runtime `mapUrl`; Discord links use its `minecraft.discord.inviteUrl`.
An empty invite omits clickable invite links, retaining the `/discord` suggestion.

The 20 tips cover homes, public homes, TPA, vein-mining, graves, the Grave Compass,
`/ec`, ordinary home/TPA `/back`, sleeping, the map, AFK, nicknames, Discord,
mini blocks, `/tpignore`, custom portals and `/rtp`. Public-home advice uses
`/edithome <name> privacy public` and `/phome <player>:<home>` (the colon matters
for Floodgate names). Voice chat, skins, LOD, `/msg`, `/spawn` and named warps
are not advertised.

Nickname advice is `/nick <aqua>Name` and `/nick reset`. The pinned Carbon
3.0.0-beta.39 [command parser](https://github.com/Hexaoxide/Carbon/blob/6e486ad3fc7757e844c9403c7efd67531e8cd730/common/src/main/java/net/draycia/carbon/common/command/commands/NicknameCommand.java)
parses permitted MiniMessage tags before applying the 3–16-character name limit
and alphanumeric/underscore filter to the **plain** name. Existing colour/reset
permissions suffice; no permissions are added. DiscordSRV's configured nickname
sync copies the plain name to linked Discord server nicknames on its three-minute
cycle while the player is online, where bot permissions and role hierarchy permit;
Minecraft colours are stripped. It is not a Discord username change or an instant
sync guarantee.

Finn chose to keep `/rtp` open to everyone. The tip describes random teleporting
into the wild and the default ten-minute cooldown. The pinned HuskHomes
4.11-9ed80cc [transaction resolver](https://github.com/WiIIiam278/HuskHomes/blob/9ed80cc/common/src/main/java/net/william278/huskhomes/util/TransactionResolver.java)
defines `RANDOM_TELEPORT(25d, 600)` and uses `Instant.now().plusSeconds` for its
cooldown. Cooldowns default to enabled and are not overridden by this repository;
players with the existing cooldown-bypass permission are exempt. This change does
not alter permissions or RTP generation settings.

The new messages follow the shared FlectonePulse/Carbon/TAB system style.
HuskHomes and AxGraves retain their existing upstream palettes; this addition does
not restyle their messages. Survey references and reuse:

| Convention                                                                               | Existing source                                                               | Join guidance                                                                                    |
| ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Muted prose `#a6adc8`, mauve names `#cba6f7`; event pink `#f5c2e7` and peach `#fab387`   | `flectonepulse-config.py:84`, `:100`, `:107`                                  | Exact hex prose/name/link components; event glyphs retain their existing meanings                |
| Private system bullet `·`, sentence case                                                 | `flectonepulse-config.py:113`                                                 | `· Welcome back, NAME!`, `· Tip: …`, welcome bullets                                             |
| Carbon sender separator `›`, text `#cdd6f4`                                              | `minecraft-chat.nix:63`                                                       | Tips follow the private system-message layout rather than impersonating chat                     |
| Bold mauve → pink → peach server-name gradient; `Map:`/`Discord:` labels, `·` separators | `minecraft-tab.nix:78`, `:85`                                                 | Same per-character gradient in the welcome; same labels and separator                            |
| Default mauve, mod `light_purple`, admin `green`, builder `gold`; rank-name hover        | `rank-icons.json:2`, `minecraft-ranks.nix:14`, `minecraft-permissions.nix:23` | Neutral system messages use mauve emphasis, without player rank badges                           |
| HuskHomes retains green `#00FB9A`, error `#FF7E5E`, hover and command suggestion actions | `minecraft-homes.nix:68`, pinned `locales/en-gb.yml:138`                      | Commands suggest input with “Click to suggest” hover; URLs open links; shared Catppuccin colours |
| AxGraves magenta gradient, `»`, white help commands                                      | `minecraft-graves.nix:84`, `:170`                                             | Grave tips use the shared system style; existing grave messages stay intact                      |

JSON text components preserve exact colours and explicit decoration boundaries;
commands and links use mauve emphasis. Commands with placeholder arguments suggest
their editable prefix, and complete examples suggest the complete command. Literal
`<name>` and `<aqua>Name` examples are text, never MiniMessage input.

The world check compiles and runs the pack on disposable pinned Paper 26.3 players,
including historical statistics and private two-line returning output. The plugin
check exercises the real Carbon colour example and reset. Installing the pack
requires the normal future approved stopped-server reconcile/start and prechange
snapshot gate. This change does not activate, restart or test the live server.

### Grave compass

The in-repo Grave Compass pack gives a vanilla recovery compass after a new
death and respawn. It waits until the player is alive and their
`minecraft.custom:minecraft.time_since_death` statistic has advanced at least
one tick. A separate pending death counter prevents grants for historical
deaths on first installation, and survives reconnects, restarts and `/reload`.
The compass is named **Grave Compass**, with the lore “Points to your last
death.” Its `minecraft:custom_data` contains `{infra_grave_compass:1b}`. An
existing tagged recovery compass in inventory or offhand suppresses another
grant; a crafted recovery compass does not. The native item always follows
the holder's latest `LastDeathLocation`.

The pack clears only tagged recovery compasses when their holder comes within
three blocks of their recorded death coordinates, in the same dimension.
Graves never expire (`despawn-time-seconds=-1`, `grave-limit=-1`), so there is
no timeout-based removal. LastDeathLocation is the source of truth: if
AxGraves relocates a grave to a safe spot after a lava or void death, the
compass points to the death spot instead. It spins normally in another
dimension. Storing or discarding it does not trigger a replacement until
another death and respawn.

Death-time cleanup is intentionally omitted. AxGraves 1.32.1 copies and clears
the drops synchronously inside `PlayerDeathEvent`, before a datapack tick can
reliably clear the old item. An old compass can therefore remain in a grave;
the next respawn still receives a fresh one. The datapack never edits grave
contents or removes nearby dropped items.

Pinned Geyser 2.12.0 build 1256 maps `minecraft:recovery_compass` directly to
Bedrock's native item and translates the Java respawn packet's last-death
position, dimension and has-died metadata. This supports the ordinary
Bedrock recovery compass without extra mappings or resource packs. Grant and
cleanup run on Paper for both clients; client rendering still needs a Java
and Bedrock smoke test after an authorized deployment.

Deploying this pack requires restarting `minecraft-server-survival` through
the normal approved activation gate: the stopped-server installer must copy
the archive before Paper loads it. `/reload` alone cannot install it. No
deployment or client test is performed by the build checks, which use a
temporary Paper world to validate functions and instantiated macros.

## Always-on service, map and resource budgets

Survival sets `minecraft.lazymc.enable=false`: Paper starts at boot, restarts on
failure, and stays running when empty. New backends default to lazymc enabled;
the wrapper, exit-proof patch and sleep/wake checks remain available. Velocity
is the public game entry and connects to Paper at `127.0.0.1:25567`. The
`minecraft-server-survival.socket` is a stdin console FIFO, not a TCP listener;
it remains required by upstream console management. Shutdown/deploy uses
`save-all flush`, `stop`, a 150-second graceful wait and a 180-second systemd
timeout. Config templates, plugin preparation and datapack installation run
only before Paper starts, with the existing pre-change clean-stop protection.

The JVM retains `-Xms1G -Xmx4G` and the service retains `MemoryMax=6G`.
Before this change, awake cgroup RAM over 24 hours was median 3.06 GiB and
peak 5.23 GiB; recheck steady-state RAM after approved activation.

Velocity answers pings even while Paper is stopped. BlueMap serves only static files
through the existing Cloudflare tunnel/service-publication framework at
`https://map.finnrut.is`; its origin is loopback nginx port 8766. Access bypass
is justified by the intentionally public, read-only map. nginx permits GET and
HEAD, rejects private dotfiles and directory indexes, and has read access to
only the web subtree. Finn approved public online player names and locations
alongside the terrain/builds. BlueMap writes `maps/<map>/live/players.json`
every three seconds while Paper is running; the bundled browser polls it through
the same static nginx route. Player JSON has `Cache-Control: no-store`.
The embedded webserver stays disabled; `live-player-markers=false` controls
that server's live supplier, independently of the static player writer.
Spectators, vanished and invisible players, and players hidden through BlueMap
are excluded. BlueMap clears online data on a clean stop; the existing
toggleable Offline Players layer retains logout markers and its banned,
spectator and hidden-player exclusions. No map request wakes Paper.

BlueMap renders to `plugins/BlueMap/web/maps` using file storage and client-side
compression handling. A single render thread at Java priority 1 runs while Paper is
running, including with players online (`player-render-limit=-1`, verified
against BlueMap 5.28). The update cooldown remains 60 seconds. The
`full-update-interval=1440` fallback checks for missed changes daily without
re-rendering every unchanged chunk. Allow the initial render to finish before
expecting a complete public map; existing tiles remain viewable during stops.

The exact vanilla 26.3 client asset JAR is preseeded through Nix with downloads
disabled. BlueMap may still request Mojang version metadata; cached assets let
it recover if that metadata request fails. Its flow-math library is pinned and
bundled at build time, removing Paper's runtime library download declaration.
Skin downloads remain enabled for player heads; BlueMap telemetry is disabled.

Paper retains `-Xms1G -Xmx4G` and MemoryMax 6G; Velocity retains a 512M maximum
heap and MemoryMax 1G. With vane deferred, these are conservative initial
budgets, not measured capacity guarantees. Monitor the existing games memory
panels, startup duration and BlueMap queue after deployment before increasing
concurrency or memory. Rendering can still consume one CPU core and write many
tiles; one render thread and low thread priority limit its resource use. The
existing games slice CPU/IO accounting and weights remain in effect. Avoid a
whole-Paper CPU quota that would throttle its tick thread.

Optional lazymc backends retain their 300-second startup timeout and 25-second
held join. Direct survival keeps the 40-minute pre-start preparation budget
and existing clean-stop limits; it has no held-join wrapper. A cold first start can require a client retry;
there are no new network dependency downloads on that path. Use Paper's
[bundled spark](https://docs.papermc.io/paper/profiling/) when investigating slow
starts or ticks; no duplicate profiler is installed.

## Permissions setup and backups

LuckPerms is enabled on both platforms only when the new encrypted
`games/minecraft/luckperms-db-password.age` exists in the pinned secrets input.
Create that secret separately; no password or ciphertext is created here.
Choose 16–256 URL-safe letters/digits/underscore/hyphen, matching the existing
runtime substitution contract. Both plugins share PostgreSQL database/role
`luckperms` on link, using loopback SCRAM authentication. A credential-aware
provisioning unit sets the role password without storing it in Nix or arguments.
No H2 fallback is allowed. After changing the password, rerun the provisioning
unit and restart the affected plugins/services during an operator maintenance
window so cached connections are refreshed.

The pinned 5.5.71 JARs require runtime libraries. All 20 selected dependencies
are hash-pinned; relocation happens during the Nix build and both platforms use
an immutable preseeded cache. Automatic translation downloads are disabled.
LuckPerms' SQL messaging queue supports MySQL/MariaDB, not PostgreSQL: this
single-proxy arrangement uses `pluginmsg` plus a one-minute database sync.
Permissions load from the shared database when Paper starts.

A deterministic gzip export, `bootstrap.json.gz`, declares the `staff` track in
order `default → builder → mod → admin`. `builder` inherits `default`; `mod`
inherits `builder`; `admin` inherits `mod`
and retains `*`. Finn's verified UUID is declared through
`gameServers.minecraft.adminUuid`; the bootstrap assigns him to `admin`.

| Group                  | Explicit grants                                                                                                                                                                                            |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| default                | Existing `skinsrestorer.command.set`, `voicechat.listen`, `voicechat.speak`, `voicechat.groups`                                                                                                            |
| default: homes         | `huskhomes.max_homes.10`, `huskhomes.command.home`, `.sethome`, `.delhome`, `.homelist`, `.edithome`, `.edithome.privacy` (all abbreviated command nodes use the `huskhomes.command` prefix)               |
| default: public travel | `huskhomes.command.phome`, `.phomelist`, `.warp`, `.warplist`                                                                                                                                              |
| default: requests      | `huskhomes.command.tpa`, `.tpahere`, `.tpaccept`, `.tpdecline`, `.tpignore`; `/tpdeny` is an alias of `/tpdecline`, so there is no separate `tpdeny` node                                                  |
| default: graves        | `axgraves.help`, `axgraves.list`, `axgraves.allowgraves`                                                                                                                                                   |
| mod                    | `minecraft.command.kick`, `velocity.command.kick`, `huskhomes.command.tp`, `minecraft.command.gamemode` plus `.survival`, `.spectator`, `.creative`, `.adventure`, `axgraves.list.other`, `axgraves.admin` |
| admin                  | `*`, inherited mod/default grants                                                                                                                                                                          |

Mod can kick, teleport themselves to a player, switch gamemode (including
creative/adventure as Finn requested), list others' graves and open them to
recover items. It gets no wildcard, ban, reload, warp creation or teleport-other
node. `axgraves.admin` is AxGraves' owner-protection bypass; this does not grant
its separate reload command. Every declared rank explicitly denies
`huskhomes.command.back.death`, `axgraves.tp` and `axgraves.tp.bypass`, including
admin so its `*` grant cannot enable grave teleporting. Ordinary `/back` grants
are unchanged. Bukkit/Velocity op accounts retain other upstream op permissions
independently of the LuckPerms groups.

Every rank also explicitly denies `discordsrv.silentjoin` and
`discordsrv.silentquit`. DiscordSRV 1.30.5 checks these permissions before
relaying joins (including first joins) and leaves; admin's `*` otherwise grants
them. FlectonePulse's in-game message configuration is unchanged.

Generating the bootstrap does not update existing LuckPerms groups. After the
separately approved activation and with Paper awake, apply just these two
denials to the live database, preserving other grants, memberships and tracks:

```fish
sudo games-console survival 'lp group default permission set discordsrv.silentjoin false'
sudo games-console survival 'lp group default permission set discordsrv.silentquit false'
sudo games-console survival 'lp group builder permission set discordsrv.silentjoin false'
sudo games-console survival 'lp group builder permission set discordsrv.silentquit false'
sudo games-console survival 'lp group mod permission set discordsrv.silentjoin false'
sudo games-console survival 'lp group mod permission set discordsrv.silentquit false'
sudo games-console survival 'lp group admin permission set discordsrv.silentjoin false'
sudo games-console survival 'lp group admin permission set discordsrv.silentquit false'
```

Run the permission commands individually, checking each asynchronous result in
`games-logs survival` before the next command. Then synchronize both platforms,
again waiting for each result before continuing:

```fish
sudo games-console survival 'lp sync'
sudo games-console velocity 'lpv sync'
```

Check each asynchronous result in `games-logs survival` and `games-logs velocity`;
an empty RCON response does not establish success. Query both nodes for each
rank with `lp group <rank> permission check <node>` and verify Finn's effective
permissions with `lp user 3f771d00-3456-4007-8d66-13fe158488fa permission check <node>`.
Both checks must report false. Confirm a subsequent admin join and leave appear
in the configured Discord events channel. These live permission updates and
syncs require no Paper, Velocity or DiscordSRV restart.

The pinned Paper and Velocity **5.5.71** jars have identical import classes
(their SHA-256 hashes match `minecraft-plugin-artifacts.nix`).
[`ImportCommand`](https://github.com/LuckPerms/LuckPerms/blob/master/common/src/main/java/me/lucko/luckperms/common/commands/misc/ImportCommand.java)
reads local files as **gzip-compressed UTF-8 JSON**, regardless of filename.
Files must be readable directly inside the plugin directory; subdirectories and
`config.yml` are rejected. It only tries appending `.json.gz` when the requested
file does not exist and its name contains no dot. Use the full
`bootstrap.json.gz` name; `bootstrap.json` is not an alias. Template preparation
copies the gzip bytes atomically as the Minecraft owner with mode `0600`.

Reapply the updated bootstrap during the death-return policy rollout using the
import and synchronization commands below. Generating the new bootstrap alone
does not update existing LuckPerms permissions. Confirm the three denials for
each declared rank, including admin, after the import finishes.

[`Importer`](https://github.com/LuckPerms/LuckPerms/blob/master/common/src/main/java/me/lucko/luckperms/common/backup/Importer.java)
merges group/user nodes by default. With `--replace`, it replaces the normal
nodes of the groups and users included in the file; unlisted groups/users are
untouched. **Tracks are always overwritten**, and supplied user primary groups
are applied even during a merge. Generated files are not ongoing database
reconciliation.

For **this server**, Finn confirmed there are no existing tracks and approved
replacing the included data. After deploying and waking Paper, follow its log
in a separate terminal:

```fish
sudo games-logs survival --follow
```

Import the declared state, then wait for the import completion message and
check for errors before querying the user:

```fish
sudo games-console survival 'lp import bootstrap.json.gz --replace'
```

This overwrites `default`, `builder`, `mod`, `admin`, Tunnelmaker's direct nodes,
and the `staff` track with the declarations. The import assigns Tunnelmaker's
verified UUID to admin. Confirm the user's admin membership in the log, then
synchronize Paper and Velocity, waiting for each asynchronous result:

```fish
sudo games-console survival 'lp user 3f771d00-3456-4007-8d66-13fe158488fa info'
sudo games-console survival 'lp sync'
sudo games-console velocity 'lpv sync'
sudo games-logs velocity
```

LuckPerms replies asynchronously: an empty RCON response is expected and does
not confirm success. Read Paper results with `games-logs survival` and Velocity
results with `games-logs velocity`. The default primary-group calculation is
`parents-by-weight`, so membership plus admin's weight of 30 determines the
displayed primary group among the declared ranks. Custom higher-weight parents
can change that display without removing admin membership.

For a **fresh database**, import once with
`sudo games-console survival 'lp import bootstrap.json.gz'`, without
`--replace`, then perform the same log verification and synchronization.

As a **secondary option for existing databases whose grants must be retained**,
inspect `/srv/games/minecraft/survival/plugins/LuckPerms/chat-inventory.commands`.
Despite the historical filename, it now contains the complete additive rank
repair: group creation, all declared inheritance and permission nodes (including
explicit denials), weights, colors, prefixes, and the configured user's admin
membership/stored primary group. Run its commands individually through
`games-console survival`, checking log completion before the next command.
Already-existing groups during creation are expected. Unrelated permissions
and memberships remain; explicitly managed permission/style values are updated.
The file does not modify tracks: inspect existing tracks separately if using
this path. It contains no import, clearing, or removal commands.

The correct command for the stored primary group is
`lp user <uuid> parent switchprimarygroup admin`; `primarygroup set admin` is
not valid. With the default weight calculation, switching the stored value
also prints a warning that the displayed group is calculated from parents.
Assign a moderator later with `lp user <uuid> parent add mod`.

## Staff rank icons

Java players must accept a small server resource pack to join. The prompt explains
that it supplies staff rank icons. Mod has a purple shield, Admin a green crown,
and Builder a gold hammer; default players have no badge. The original 9px pixel
grids in `modules/games/rank-icons.json` generate the PNGs and ZIP reproducibly.
The pinned 26.3 client supplies resource-pack format 97.1. Nix computes the ZIP's
SHA-1 when building `server.properties`, and nginx serves its versioned URL from
`https://map.finnrut.is/packs/` even while Paper is stopped. Declining the required
pack, or failing to download it, prevents a Java player from joining.

LuckPerms prefixes contain MiniMessage translation components with explicit text
fallbacks and rank-name hover tooltips. The pack translates `infra.rank.mod`,
`infra.rank.admin`, and `infra.rank.builder` to U+E100, U+E101, and U+E102 in the
default font. Without those translations, clients display colored `[Mod]`,
`[Admin]`, or `[Builder]` labels. Bedrock intentionally uses these labels: no
Bedrock font pack is installed. Pinned Geyser 2.12.0 build 1256 acknowledges
required Java packs without downloading them and honors component fallbacks.
Changing that pin must preserve both behaviors. Hover tooltips are a Java feature.

Chat consumes `<luckperms_prefix>` and `chat_color` metadata. TAB consumes the
same prefix through `%luckperms-prefix%` with MiniMessage enabled; the pinned
renderer round-trip test verifies its translation key, fallback and tooltip,
including Java pack glyphs and Geyser text fallback. There is no separate tab badge
palette. Discord webhook chat uses usernames and message bodies only, so rank
glyphs do not enter Discord-bound formatting.

Deploying updated files does not reconcile LuckPerms' PostgreSQL nodes. For the
declared groups/users, apply the new prefixes with the existing approved
replacement import after Paper starts:

```fish
sudo games-console survival 'lp import bootstrap.json.gz --replace'
sudo games-console survival 'lp sync'
sudo games-console velocity 'lpv sync'
```

**Wait for completion in the Paper log between these commands**, and check the
proxy log after its sync; RCON replies do not establish asynchronous completion.
The replacement import also replaces the declared groups/users and staff track,
as described above. If unrelated interactive grants must be preserved instead,
use the generated `chat-inventory.commands` repair commands and verify each
asynchronous result. Existing legacy prefixes remain readable until this update
is applied. Verify Java badges and Bedrock labels after reconnecting.

## Homes, requests and graves

HuskHomes uses local SQLite at
`/srv/games/minecraft/survival/plugins/HuskHomes/HuskHomesData.db`;
cross-server messaging, Redis and economy integration are disabled. All friends
start with 10 homes without manual grants; the config fallback is also 10,
with permission stacking disabled. `/sethome <name>`, `/homes`, `/home <name>`
and `/delhome <name>` work across Overworld/Nether/End. Teleports have a
five-second warmup cancelled by movement/damage; requests expire after 60 seconds.
Use `/tpa <friend>`, `/tpahere <friend>`, `/tpaccept` and `/tpdeny`.

HuskHomes' `general.back_command.return_by_death` is explicitly false: deaths
no longer record a return point or send the clickable death-return notification.
Its help describes `/back` only as returning to the previous position. Ordinary
`/back` after a normal teleport retains its existing settings and permissions.
Previously saved return points are deliberately preserved; an old death point
can remain usable until a normal teleport replaces it. No database reset is
performed.

The BlueMap hook publishes **public** homes and warps as marker sets.
`/edithome <name> privacy public` publishes a home; `privacy private` hides it.
The home delimiter is `:` instead of `.` because Floodgate names start with
`.`: e.g. `/phome .BedrockFriend:base`. Private homes stay private. Publishing
exposes the name/location on the public map at `map.finnrut.is`. BlueMap writes
home/warp marker sets every 30 seconds while Paper is running, independently of
the three-second online player feed. HuskHomes clears its marker sets when
disabled, so home/warp markers can disappear during maintenance; they
repopulate after Paper starts. The static terrain map remains viewable throughout.
Admins create warps with `/setwarp <name>`; regular friends can list/use them.

HuskHomes' six declared driver/Redis dependencies load unconditionally, even
with SQLite-only settings. `huskhomes-libraries.json` pins the full closure
(14 JARs and 28 parent/BOM/dependency POMs). Immutable per-version directories
preseed Paper's `libraries` Maven cache with repository identity; the real
HuskHomes loader and pinned Paper 26.3 resolver are checked with zero transfers.
Update checks are off. Installing the Jedis library does not enable Redis.

AxGraves retains **100% XP** and items in graves with no timed expiry or grave
count eviction. Empty graves disappear. Only the owner can open or instantly
loot their grave, with the documented mod/admin recovery bypass for opening.
`/graves list` lists one's graves. State is `plugins/AxGraves/data.json`, saved
on shutdown and every 30 seconds; backups include the whole plugin directory.
Players must travel back to recover a grave. Grave teleport commands are denied
for every declared rank. Help omits `/axgraves tp`, and grave listings retain
their world/coordinates without the `[TP]` advertisement. The pinned AxGraves
still attaches a click command to list entries, but the `axgraves.tp` denial
prevents it from teleporting the player.
The ordinary grave interaction and inventory GUI use the Java Player UUID
provided by Floodgate; no Java client mod or resource pack is required for
Bedrock. Both normal and sneak instant-pickup ownership protections are enabled.

AxGraves includes an AxAPI runtime downloader. `axgraves-libraries.json` pins
its exact `v26_3` adapter (`2.2.0-DEV-NEW-VERSION-6`, `all` classifier), commons-math3,
Caffeine and dependencies, ASM and jar-relocator. Nix relocates jars and preseeds
the exact immutable cache and metadata at `plugins/AxAPI/libraries/AxGraves`.
Missing/changed cache metadata would trigger upstream downloads, so version
upgrades must refresh pins, relocation rules and offline checks together.
Update notifications are disabled; neither plugin adds credentials or changes
the existing mandatory-credential startup gate.

After deployment, verify with a non-op Java friend and a Bedrock friend: set
10 homes and reject an 11th; travel between dimensions; accept/deny both request
directions; publish/hide a BlueMap home and test a warp. Verify ordinary `/back`
after a normal teleport, then die and check that no death-return button appears
and `/back` does not return to the new death point. Check `/graves tp`,
`/axgraves tp` and clicking a grave listing are denied, including as admin after
reapplying the bootstrap. For graves, die with items/XP, deny another friend's
access, walk back and recover as owner/mod, then cleanly stop
and start Paper and recover a still-filled grave. These are operator smoke tests;
the Nix checks do not claim a live client integration test.

Mutable backend plugin directories remain included with world snapshot roots.
For active always-on Paper, game backups briefly issue `save-off`, confirm
`save-all flush`, take a read-only snapshot of the existing `/srv` Btrfs
subvolume, then issue `save-on` **before** restic uploads. A private mount
namespace exposes the frozen view at the original paths, preserving restores.
Snapshots live temporarily under root-owned `/srv/.games-backup-snapshots` and
are removed after success or failure. Backups refuse roots in other/nested
subvolumes rather than silently omit data. No filesystem migration is required.

An intent record is persisted before `save-off`. Errors, lost replies and
cancellation retry `save-on`; ExecStopPost and a boot/30-second recovery timer
also recover interrupted attempts. If saving cannot be acknowledged, recovery
restarts Paper, or stops it if restart fails, so it cannot keep running with
saving disabled. That exceptional recovery interrupts players and reports a
failed backup. Healthy online backups preserve connections and the invocation.

SQLite databases and their WAL/journal files share the frozen disk view.
Plugin state has its existing persistence interval (AxGraves saves every 30
seconds); this is a persisted-state snapshot, not a transaction across every
plugin. Stopped servers, optional lazymc backends and Terraria keep clean-stop
backups. Configuration/datapack changes still require the pre-change verified
clean-stop snapshot. JAR/cache symlinks do not replace pinned Nix artifacts.

Backup enablement is unchanged: initialize the NAS repository and configure
`gameServers.backup.enable` before using `sudo games-backup survival`. After
approved deployment, run the first configured online backup manually and
verify its completion, saving-enabled response, cleanup and a restore into a
separate directory before relying on the schedule. Builds never run a real
world backup; the Btrfs/Restic restore check uses a disposable VM filesystem.

The existing server backup additionally covers proxy SkinsRestorer/LuckPerms
state and an atomic PostgreSQL custom-format dump under
`/var/backup/games-luckperms`. That shared/proxy backup is separate from the
world's snapshot; there is no cross-service point-in-time guarantee.
Restore permissions deliberately alongside a world restore. Plugin snapshots
can contain private configuration and must stay in encrypted backups; supply
current agenix credentials again rather than relying on restored credentials.
BlueMap tiles are rebuildable but included in incremental backups.

## Voice chat operator steps

UDP 24454 is open in link's Nix firewall and advertised as
`survival.mc.finnrut.is:24454`. Add a router UDP port forward to link; router
forwarding is not managed in this repo. The existing dynamic DNS record is the
public address; do not route UDP through the HTTP Cloudflare tunnel.

The official [proxy setup](https://modrepo.de/minecraft/voicechat/wiki/proxy_setup)
allows a directly exposed backend with `voice_host` when no proxy plugin is
used. This is the selected arrangement for the single backend. Do not install
the unverified proxy alpha merely for this topology. Java clients need the
matching Simple Voice Chat client mod. Voice chat is optional, and Bedrock
clients cannot use that Java mod. Survival runs continuously; UDP voice
packets alone do not.

## Discord operator steps

Classic DiscordSRV is chosen over [Ascension](https://github.com/DiscordSRV/Ascension):
classic has a released 26.3 build, while no suitable published Ascension release
was verified. Ascension's proxy architecture could keep a bot connected during
sleep, but death/advancement events would still need a backend integration.
Classic remains connected while always-on survival is idle. Its status card and
channel topic reflect running, starting, stopped, disabled or failed states;
normal idle time is not announced as resting. Optional lazymc backends retain
the resting/wake behavior. Maintenance stops disconnect the bot, and Discord
messages sent during that outage are not queued.

Finn already has a bot. Configure its token separately as
`games/minecraft/discordsrv-token.age` in the secrets repository, with the
appropriate link recipients/rule, then refresh the pinned secrets input when
ready. Do not paste it into this repo. The Minecraft module's Python preparation
hook runs after `games-prepare`, copies the credential to DiscordSRV's supported
private `.token` file, and strips surrounding whitespace, including trailing
newlines. It drops to the Minecraft account before writing plugin paths and
atomically creates the file with mode `0600`; an empty token fails preparation
without logging its value. The original agenix file is untouched. Internal
characters and periods are preserved. Generic raw-byte copying remains unchanged
for binary secrets such as Floodgate's key.

Survival declares the following `gameServers.servers.survival.minecraft.discord`
options for Finn's existing bot:

| Option             | Discord ID            | Purpose                                           |
| ------------------ | --------------------- | ------------------------------------------------- |
| `guildId`          | `1518484285466873997` | Guild owning the channels                         |
| `channelId`        | `1557960229528797265` | Main bidirectional chat, deaths and advancements  |
| `linkChannelId`    | `1559824382208253973` | `#mc-link`, accepting account-link codes          |
| `linkedRoleName`   | `1559828466336145408` | Discord channel access on link; removed on unlink |
| `eventsChannelId`  | `1518484285982769204` | Join, first join and leave messages               |
| `consoleChannelId` | `1557960243101831168` | Private Paper logs and diagnostic commands        |
| `roles.builder`    | `1559828413437583360` | LuckPerms `builder` → Discord Builder             |
| `roles.mod`        | `1558172717218533468` | LuckPerms `mod` → Discord Mod (purple)            |
| `roles.admin`      | `1558173111931904092` | LuckPerms `admin` → Discord Admin (green)         |

The defaults for other servers are empty. Either missing guild/chat ID, missing
encrypted token source or `enable = false` means no DiscordSRV JAR is installed;
Minecraft retains vanilla whitelist enforcement and its existing mandatory
credential checks. DiscordSRV resolves its main guild from the chat channel;
the login requirement separately names the configured `guildId` explicitly.
Use Discord Developer Mode to copy the IDs and ensure the bot is in that guild.
An empty events ID keeps join/leave messages in chat; an empty console ID
disables console forwarding without disabling the bridge.

The pinned stock 1.30.5 JAR's `config/en.yml`, `messages/en.yml`,
`synchronization/en.yml` and `linking/en.yml` were inspected.
Routing uses `Channels.global`, `Channels.join` and `Channels.leave`; the message
templates have no channel selector. Deaths and advancements use distinct
`deaths`/`awards` routes and fall back to the first channel, `global`, here.
Server startup/shutdown messages also remain in chat.

The bot displays **Playing mc.finnrut.is · N online**, keeping the address and
live Minecraft count in one activity. `DiscordGameStatus` is
`playing mc.finnrut.is · %online% online`; `StatusUpdateRateInMinutes = 1`
refreshes it once a minute. The pinned JAR's `PresenceUpdater` expands `%online%`
from visible online Minecraft players, excluding players hidden by supported
vanish hooks. It supports playing, watching, listening to, competing, custom
statuses without a prefix, and lists that rotate, but this server uses one
playing activity. No PlaceholderAPI expansion is needed for this count.

`EnablePresenceInformation = false` remains deliberate. In the pinned JAR
(manifest revision `da9e027f7acd76e0f91d53a11e5b53832ac36e92`),
[startup requests `GUILD_PRESENCES` and activity/client-status caches only when
that option is enabled](https://github.com/DiscordSRV/DiscordSRV/blob/da9e027f7acd76e0f91d53a11e5b53832ac36e92/src/main/java/github/scarsz/discordsrv/DiscordSRV.java#L808).
Those support DiscordSRV placeholders about Discord members' status and games;
neither native `%online%` nor normal PlaceholderAPI substitution needs them.
PlaceholderAPI status expansion runs without a player context, so any future
placeholder must have an installed expansion that supports that context.
Enabling presence information also requires the **Presence Intent** enabled
and authorized in the Developer Portal: otherwise Discord closes the gateway
with [code 4014](https://docs.discord.com/developers/events/gateway#privileged-intents)
and the pinned `DiscordDisconnectListener` disables DiscordSRV.

A Minecraft game icon cannot be configured for this activity. Discord allows
bots to set only activity name, state, type and URL, excluding application IDs
and Rich Presence assets; the playing text does not supply a game icon.
See [Discord's activity contract](https://docs.discord.com/developers/events/gateway-events#activity-object).

Enable **Message Content** and **Server Members** privileged intents. Grant
**View Channel**, **Send Messages**, **Read Message History** and **Embed Links**
in the chat and events channels. Make the events channel read-only to ordinary
members so it remains a bot event feed. Grant the bot **Manage Roles** for rank
synchronization; its invite permission bit is `268435456` (OR it with the
existing permission integer when updating an invite). No Administrator
permission is needed. Member presence information, chat-channel console commands,
topic edits and ban synchronization remain disabled. Mandatory account linking is
enabled for Survival as described below. Join/leave, first join,
death, advancement and bidirectional chat messages are enabled. Test them after
the first configured start. Confirm token permissions remain private and neither
configuration nor logs expose it.

Keep Discord roles **Builder**, **Mod (purple)** and **Admin (green)**. Colours
are set in Discord's role editor, not by DiscordSRV. Put Admin above Mod above
Builder and the bot's own role **above all three** in the role list; Manage Roles
cannot manage roles at or above the bot's role. Enable **Developer Mode**,
right-click each role and select **Copy Role ID**. Set those IDs in Survival's
`gameServers.servers.survival.minecraft.discord.roles.builder`, `.roles.mod`
and `.roles.admin` declarations. These options default to empty on other servers.
Only nonempty IDs are mapped; with all three empty, linking remains available but rank sync is
inert and Vault is not installed. Missing token/guild/chat IDs or a disabled
bridge still prevent DiscordSRV and Vault installation.

### Linking channel and visibility

The pinned 1.30.5 JAR's `DiscordAccountLinkListener` accepts codes in
`Channels.link`, independently of `MinecraftDiscordAccountLinkedUsePM = true`,
which also permits DMs. Survival maps `Channels.link` to `1559824382208253973`;
this channel is excluded from the Minecraft chat bridge by `DiscordChatListener`.
Both routes use the same account-link manager. Codes are four digits; the
file backend strips non-digits before lookup and consumes a successful code.
Send just the displayed code, without a command prefix.

`MinecraftDiscordAccountLinkedRoleNameToAddUserTo` uses the declared
`minecraft.discord.linkedRoleName`, set to role ID **1559828466336145408** for
Survival. The option keeps its existing name for compatibility and accepts a
role ID or unique role name; empty disables it. The pinned
[`resolveRole` matches a name or ID](https://github.com/DiscordSRV/DiscordSRV/blob/da9e027f7acd76e0f91d53a11e5b53832ac36e92/src/main/java/github/scarsz/discordsrv/util/DiscordUtil.java#L734).
Using the ID keeps the linked role stable when its display name changes.
Other servers default to an empty linked role and link channel ID.
The role is independent of LuckPerms staff mappings:
`AbstractAccountLinkManager` grants/removes it directly when group sync is off,
and `GroupSynchronizationManager` handles it alongside staff roles when sync is
on. Linking therefore grants Minecraft-channel visibility without a Minecraft
rank or console command.

Neither `minecraft-discord-token.py` (private token preparation) nor
`minecraft-discord-status.py` (status-message delivery) manages guild roles or
channel permissions. Finn must apply these settings in Discord:

1. In **Server Settings → Roles**, keep the **linked** role with ID
   `1559828466336145408`. Grant the bot **Manage Roles** and drag its role above
   **linked**, Builder, Mod and Admin. Retain the existing Message Content and
   Server Members intents.
2. Open **Edit Channel → Permissions → Advanced permissions** for the Minecraft
   channels and set the following overrides. If using a category for chat,
   events or voice, synchronize only channels that should share its settings;
   `#mc-link` needs its own overrides.

   | Channel                     | `@everyone`                                             | `linked`                                                | Bot                                                                                            |
   | --------------------------- | ------------------------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
   | `#mc-link`                  | Allow View Channel, Send Messages, Read Message History | Deny View Channel                                       | Allow View Channel, Send Messages, Read Message History, Manage Messages                       |
   | Minecraft chat              | Deny View Channel                                       | Allow View Channel, Send Messages, Read Message History | Explicitly allow View Channel; retain existing sending, history, embed and webhook permissions |
   | Minecraft events            | Deny View Channel and Send Messages                     | Allow View Channel and Read Message History             | Explicitly allow View Channel; retain existing sending, history and embed permissions          |
   | Minecraft voice, if present | Deny View Channel                                       | Allow View Channel, Connect and Speak                   | Retain existing permissions                                                                    |

3. Keep the console channel operator-only. Leave non-Minecraft channels alone.
   Remove other ordinary-role or member-specific View Channel allows that
   bypass the gate or prevent **linked** from hiding `#mc-link`. Administrator
   and server-owner accounts bypass channel restrictions; verify with ordinary
   unlinked and linked members. See [Discord's permission rules](https://docs.discord.com/developers/topics/permissions).
4. Before enforcing visibility, inspect existing associations with
   `/discordsrv linked <verified Minecraft UUID or Discord ID>` and manually
   grant **linked** to verified existing members missing it. Do not unlink
   existing accounts merely to populate the role.

`MinecraftDiscordAccountLinkedMessageDeleteSeconds = 1` enables native cleanup.
In this exact JAR, channel replies are delayed one second, then both the reply
and the submitted message are deleted after the reply sends. **Manage Messages**
is needed to delete another member's code. Failed or unknown codes receive the
same channel cleanup. Successful codes are consumed before the delayed reply;
the success/error text does not repeat the code. DMs receive their reply directly
and are not subject to channel cleanup. Discord deletion remains best-effort
when permissions or connectivity fail.

The success reply is `Linked to %name%. Rejoin Minecraft.` A successful channel
link grants the role before replying, so `#mc-link` may disappear before the
member sees a reply. The appearance of the Minecraft channels is the signal to
rejoin; use DMs when a readable confirmation is preferred. Pin an instruction
in `#mc-link`: join `mc.finnrut.is`, post just the displayed code here or DM the
bot, then rejoin once the Minecraft channels appear.

After separately approved activation, restart `minecraft-server-survival` to
prepare and load the generated DiscordSRV configuration. Discord permission
edits themselves need no Minecraft restart. Verify both linking routes, code
cleanup, role assignment and removal, and visibility with an ordinary member.

### Mandatory Discord onboarding

Survival sets `minecraft.discord.requireLinkedAccount = true`; other servers
default to false. When the bridge is configured (enabled, encrypted token source
present, guild/chat IDs set, and the owner exemption valid), a shared Nix value
enables the stock login check and generates `white-list=false` and
`enforce-whitelist=false`. Missing prerequisites retain both whitelist settings
as true. This is configuration readiness, not proof that the token, bot or
Discord connection works at runtime.

For a new player:

1. If you have **both Java and Bedrock**, complete global linking at
   **[link.geysermc.org](https://link.geysermc.org/)** first, before redeeming any
   Discord code. Bedrock-only players can skip this step.
2. Join `mc.finnrut.is`. An unlinked player is disconnected with a friendly
   short message: **Post CODE in #mc-link or DM BOT to join.** Join
   **[Finn's Discord](https://discord.gg/hHurpHK8RT)** if needed; the short kick
   prompt contains no invite URL. A Paper restart can
   require another connection attempt before the bot is ready.
3. **Post just the displayed code in #mc-link or DM the bot** from the Discord
   account you want linked. Paper must be running to redeem it.
   After a maintenance restart, join Minecraft again to obtain another code.
4. In DMs, wait for the bot's confirmation. In `#mc-link`, wait for the Minecraft
   channels to appear and the linking channel to disappear, then rejoin Minecraft. `/discord linked`
   checks the association once you are in game. Finn can also use `/discord link`
   from his exempt account.

The pinned `RequireLinkModule` looks up the Discord association by the Minecraft
UUID and generates the code during `AsyncPlayerPreLoginEvent` at `LOWEST`.
`Not linked message` substitutes `{BOT}`, `{CODE}` and `{INVITE}`;
`Messages.Not in server` substitutes only `{INVITE}`. The generic verification
error message gets its invite rendered by Nix because upstream does not perform
that substitution there. There is no Bedrock-specific kick template in this
setup, so the Java/Bedrock ordering warning is included for everyone.

**Owner exemption:** Finn is `Tunnelmaker`, UUID
`3f771d00-3456-4007-8d66-13fe158488fa`, already declared as
`gameServers.minecraft.adminUuid`. While the Discord gate is enabled, the
generated `whitelist.json` contains exactly that entry. Stock
`Whitelisted players bypass check` compares UUIDs even when vanilla whitelist
enforcement is off, allowing Finn through before DiscordSRV is ready or without
a Discord link. Name bypasses are empty; no staff group, wildcard permission or
other former manual whitelist entry receives this exemption. Nix rejects a
configured gate without exactly one whitelist entry matching the owner UUID.
The list is configuration; Discord's account-link records are left untouched.

`Must be in Discord server` is the string guild ID `1518484285466873997`, rather
than boolean `true` (which accepts any mutual guild). Subscriber-role checks are
disabled: friends do not need a staff role. With the configured guild available,
stock DiscordSRV checks the linked Discord member and denies outsiders. A guild
departure retains the account association and is checked on the next login;
there is no continuous membership check or promise of an immediate kick for an
already connected player.

**Accepted upstream failure behavior:** before initialization finishes, an active
login listener denies non-exempt players with the retry message. Later Discord
or bot outages can prevent code redemption or verification; linked players are
not guaranteed admission. Member retrieval can use JDA's cached members. In
1.30.5 an unresolved required guild only logs and continues for linked players,
and certain initialization/token/intent failures disable DiscordSRV and remove
its login listener. If that happens with vanilla whitelist enforcement off,
Paper can admit players without this check. Finn accepts this stock behavior;
no plugin patch, runtime whitelist safeguard or outage bypass was added.
The pinned [guild-check source](https://github.com/DiscordSRV/DiscordSRV/blob/da9e027f7acd76e0f91d53a11e5b53832ac36e92/src/main/java/github/scarsz/discordsrv/modules/requirelink/RequireLinkModule.java)
and [plugin lifecycle](https://github.com/DiscordSRV/DiscordSRV/blob/da9e027f7acd76e0f91d53a11e5b53832ac36e92/src/main/java/github/scarsz/discordsrv/DiscordSRV.java)
describe these limits.

### Java, Bedrock and changing links

Floodgate **2.2.5 build 141** on Velocity now declares `player-link.enabled=true`
and `enable-global-linking=true`. `require-link=false` keeps Bedrock-only players
supported; `enable-own-linking=false` avoids a local linking database. Its pinned
`VelocityListener` uses `FloodgatePlayerImpl.getCorrectUniqueId()` and
`getCorrectUsername()` for the forwarded profile: a global link selects the
Java account's UUID/name; a standalone account uses its XUID-derived Floodgate
UUID and dot-prefixed name. Velocity's online authentication and modern Paper
forwarding retain those identities; Paper's backend `online-mode=false` is
unchanged. No backend Floodgate plugin is needed for this login identity.

| Order                                                     | Identity and progress                                                                                                                                                                                                                                                                                    |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Java first, global Bedrock/Java link before Bedrock joins | Discord binds to the Java UUID; both editions use the same Java identity and progress.                                                                                                                                                                                                                   |
| Bedrock only                                              | Discord binds to the standalone Floodgate UUID; no Java account is required.                                                                                                                                                                                                                             |
| Bedrock first, Java linked later                          | The global link selects the Java UUID. Standalone inventories, homes and other UUID-bound data remain stored under the original Floodgate identity; they are not migrated to Java. The original Discord association may need operator-assisted unlinking before the new identity's code can be redeemed. |

Enabling global linking also selects the Java identity for accounts already
linked at Geyser. It does not merge inventories, rewrite UUIDs in saved data or
move Discord associations. Floodgate's pinned lookup-error path logs the error
and falls back to a standalone identity; if you expected your Java identity,
retry when the service works instead of redeeming a standalone Discord code.

The verified [Geyser global-link procedure](https://geysermc.org/wiki/floodgate/linking/)
is to connect both editions to `link.geysermc.org` (Java TCP 25565, Bedrock UDP
19132), run `/linkaccount` on one account, then `/linkaccount <code>` on the
other. Successful linking disconnects both accounts. To undo that global link,
join its linking server with either account and run `/unlinkaccount`; relink
with the same two-account procedure. These commands belong on the global
linking server, not Survival. Global unlinking does not unlink Discord and can
make the original standalone Bedrock data accessible again.

For a Discord association change, ask Finn to inspect
`/discordsrv linked <verified Minecraft UUID or Discord ID>`, then use
`/discordsrv unlink <same verified identifier>` deliberately. Unlinking requires
operator permissions; using an identifier avoids uncertain display names.
Non-exempt online players are kicked on unlink. Rejoin Survival to get a new
code and post it in `#mc-link` or DM it after settling the Java/Bedrock identity. Redeeming a new code
cannot automatically replace an existing association. Linking executes no
console commands; the separate **linked** Discord role controls channel visibility.

These are operator/player instructions, not automatic database edits or inventory
migrations. Config and pinned implementation checks do not constitute a live
integration test. Java/Bedrock onboarding, guild departure/rejoin and outage
behavior remain **live-unverified** until separately authorized deployment and
testing; no service restart or Discord/account changes are part of this change.

LuckPerms group membership is authoritative. Both
`GroupRoleSynchronizationMinecraftIsAuthoritative = true` and
`GroupRoleSynchronizationOneWay = true` are required for **Minecraft → Discord
only**. `default` is never mapped. All memberships, including inherited groups,
count: a mod inherits builder and receives Builder and Mod; an admin inherits
mod and builder and receives all three mapped roles. The existing LuckPerms
bootstrap declares `builder → default`, `mod → builder`, and `admin → mod`;
this mapping adds no permissions or membership grants.
Sync runs on linking and periodically every five minutes for online players;
full-guild cycling is disabled. Discord role grants/removals cannot create or
remove LuckPerms membership and are reconciled to Minecraft membership on the
next sync. Unlinking removes managed roles without changing Minecraft ranks.

Group sync requires Vault's permission API. Vault **1.7.3** is pinned and
installed only on configured Paper backends with at least one role mapping;
its update checking is disabled. Despite its age, an isolated startup on the
pinned Paper **26.3 build 159** confirmed it enables and LuckPerms **5.5.71**
registers its Vault hook. VaultUnlocked was not needed. DiscordSRV continues to
use the existing LuckPerms groups rather than a separate permission store.

DiscordSRV's existing Discord-to-Minecraft message format uses
`%toprolecolor%`, so the top Discord role's colour also appears in Minecraft
chat: purple for Mod and green for Admin when these are the highest roles.
LuckPerms rank prefixes are consumed by CarbonChat; see Staff rank icons for
the shared prefix contract with the tab formatter. Discord role synchronization
does not change these Minecraft prefixes.

The JDBC account-link backend is explicitly empty, selecting DiscordSRV
1.30.5's default local `accounts.aof` storage under
`/srv/games/minecraft/survival/plugins/DiscordSRV`. The whole directory is
already included in clean-stop backups. Account records remain mutable player
state and are never replaced by a generated Nix file.

After deployment, test with a linked account: grant/remove `builder`, `mod` and
`admin` in LuckPerms and confirm the corresponding Discord roles follow
(including inherited Builder for Mod and Builder/Mod for Admin). Grant a mapped
role directly in Discord to a linked default player and confirm LuckPerms stays
default; the role should disappear on resync. Check that removing a Discord role
does not demote Minecraft, that
unlinked players get no roles, and that `/discord unlink` removes managed roles.
An operator can run `/discord resync` to avoid waiting for the periodic cycle.

**Lock the console channel's permissions to Finn.** Deny other members View
Channel and Send Messages, and permit Finn and the bot to access it, including
any inherited role permissions. DiscordSRV does not check operator roles for
console-channel commands: anyone able to post can run the allowed commands.
The whitelist is exactly `list` and `tps`, with
`DiscordConsoleChannelBlacklistActsAsWhitelist = true`; no other command names
are allowed. Bot commands and command execution from the chat channel are
disabled. INFO/WARN/ERROR Paper logs are forwarded every five seconds. Treat
these logs as private. Forwarding and diagnostics stop during maintenance; Discord commands do not
start a stopped Paper service.

## Metrics

TickScope is preferred over sladkoff's older 3.1.2 exporter, which did not have
verified 26.3 release support. It binds only to `127.0.0.1:9225`, collects every
30 seconds and is scraped every 60 seconds under job `minecraft-paper`.
Entity-type breakdown is off; slow scans inspect at most eight chunks per tick.
Selected tick/world/JVM series complement the passive exporter; player, process
and state series remain owned by games-metrics.

Sleeping Paper produces a scrape gap. The job is excluded from generic
exporter-down alerts, and no missing-exporter/TPS alert or startup dependency
is added. A broken TickScope endpoint fails silently as Finn requested. Treat
missing samples as unavailable, not zero. No TickScope runtime smoke harness is
introduced; config, gating and scrape policy are checked declaratively.

## Deferred gameplay and rollback work

**vane:** latest [1.21.1](https://github.com/oddlama/vane/releases) targets Paper
1.21.11, with no verified 26.3 release. Do not install an incompatible JAR or
downgrade the survival world. Revisit after a compatible release. Enable its
available gameplay modules by default, but omit vane-permissions because
LuckPerms owns permissions and avoid redundant proxy/sleep functionality. Its
required [resource pack](https://github.com/oddlama/vane/wiki/Hosting-the-resource-pack)
would be version/hash pinned, served statically through the publication
framework, and required via Paper's Java resource-pack prompt. Bedrock needs a
verified converted pack and Geyser mappings before resource-dependent gameplay
is enabled. Reassess memory and startup time with the actual enabled modules.

**Block logging:** defer for now; existing backups provide whole-world recovery,
not per-block inspection or rollback. The comparison as of 2026-10-08:

| Candidate                                                                                | Release / compatibility                                  | Storage, features and performance considerations                                                                                       |
| ---------------------------------------------------------------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| [CoreProtect CE](https://www.spigotmc.org/resources/coreprotect-community-edition.8631/) | 24.1; maintained, published support through 26.2         | SQLite/MySQL; mature inspect/lookup/rollback/restore with queued logging; no PostgreSQL                                                |
| [CoreProtect paid](https://www.patreon.com/cw/coreprotect/sitemap)                       | 25.0 supports 26.3; paid artifact unavailable here       | Adds DuckDB/ClickHouse; [native memory, thread and driver budgets](https://docs.coreprotect.net/config/) need attention; no PostgreSQL |
| [Prism](https://github.com/prism/prism/releases/tag/v4.4)                                | 4.4; maintained, released support through 26.2           | H2/SQLite/PostgreSQL/MySQL/MariaDB; inspect, rollback preview, restore and undo; streamed/batched operations bound work                |
| [Original LogBlock](https://github.com/LogBlock/LogBlock)                                | No verified 26.3 release                                 | MySQL; inspect/lookup/rollback and queued writes, but adds another database engine here                                                |
| [Tracel](https://hangar.papermc.io/arnodoelinger/Tracel/versions/1.0.0-preview.1)        | 1.0.0-preview.1 lists 26.3; first preview released today | Compact custom storage, inspect, preview/undo and crash-resumable rollback; very little release history                                |
| [Spyglass](https://github.com/firestarter/spyglass)                                      | Preview, no verified 26.3 release                        | SQLite or external databases, extensive audit/rollback; aimed at larger servers and not the default for this small survival server     |

Prism is the preferred future fit once it publishes verified 26.3 support. Its
PostgreSQL backend can reuse link's existing operations and avoid embedded-file
contention for concurrent history queries. Benchmark bounded queues/rollback
batches on link and verify shutdown flush/WAL behavior before enabling it. No
rollback database or speculative plugin is provisioned now.

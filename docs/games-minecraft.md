# Minecraft survival on link

Dawarich now uses `https://dawarich.finnrut.is`. Update the location-upload
app's server URL to that hostname. `map.finnrut.is` is reserved for BlueMap;
there is no redirect from that name to Dawarich and no data migration.

## Installed set and compatibility

Verified on 2026-10-09. Every release JAR uses an exact URL and SHA-256 in
`minecraft-plugin-artifacts.nix`; downloads were hashed before pinning. No
plugin JAR is fetched or updated at runtime. Configurations use Nix formats.

| Plugin             | Version / placement            | Evidence                                                                                                                                                                                                                                   |
| ------------------ | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| SkinsRestorer      | 15.12.6 / Velocity and Paper   | [26.3 fixes](https://github.com/SkinsRestorer/SkinsRestorer/releases/tag/15.12.6); [release source targets Velocity 4.2.0](https://github.com/SkinsRestorer/SkinsRestorer/blob/15.12.6/gradle/libs.versions.toml)                          |
| MiniMOTD           | 2.2.5 / Velocity               | [Release](https://github.com/jpenilla/MiniMOTD/releases/tag/v2.2.5); [source](https://github.com/jpenilla/MiniMOTD/tree/v2.2.5/platform/velocity) ping, command and favicon calls inspected against the pinned Velocity 4.2.0 build 30 API |
| BlueMap            | 5.28 / Paper                   | [Explicit Paper 26.3 support](https://github.com/BlueMap-Minecraft/BlueMap/releases/tag/v5.28)                                                                                                                                             |
| LuckPerms          | 5.5.71 / Velocity and Paper    | [Paper 26.3 release](https://modrinth.com/plugin/luckperms/version/v5.5.71-bukkit), [Velocity release](https://modrinth.com/plugin/luckperms/version/v5.5.71-velocity); Finn explicitly approved Velocity compatibility                    |
| Simple Voice Chat  | bukkit-2.6.24 / Paper          | [26.3 release](https://hangar.papermc.io/henkelmax/SimpleVoiceChat/versions/bukkit-2.6.24)                                                                                                                                                 |
| TickScope          | 2.0.1 / Paper                  | [Maintained release](https://github.com/gzimbric/TickScope/releases/tag/v2.0.1), [26.3 compatibility](https://hangar.papermc.io/gzimbric/TickScope/versions/2.0.1)                                                                         |
| DiscordSRV classic | 1.30.5 / Paper                 | [26.3 release](https://modrinth.com/plugin/discordsrv/version/1.30.5)                                                                                                                                                                      |
| Vault              | 1.7.3 / Paper (rank sync only) | [Pinned release](https://github.com/MilkBowl/Vault/releases/tag/1.7.3); isolated Paper 26.3 build 159 startup and DiscordSRV's LuckPerms provider lookup passed                                                                            |
| HuskHomes          | 4.11-9ed80cc **alpha** / Paper | [Pinned release metadata](https://api.modrinth.com/v2/version/eXHdkjXf) explicitly lists Paper and 26.3; [source commit](https://github.com/WiIIiam278/HuskHomes/commit/9ed80cc)                                                           |
| AxGraves           | 1.32.1 / Paper                 | [Release supports 1.20.2–26.3](https://hangar.papermc.io/Artillex-Studios/AxGraves/versions/1.32.1), published September 26, 2026                                                                                                          |

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
Both the MOTD and icon remain available while Paper sleeps because Velocity
answers server-list pings. The native icon remains the fallback if MiniMOTD
is removed.

SkinsRestorer uses file storage and Paper proxy detection `AUTO`; backend API
calls requiring database storage are disabled. Both installations have the
upstream `noautoupdate.txt` sentinel. Skin lookups still use normal upstream
skin services; this is separate from downloading plugin code.

Custom `minecraft.plugins` names cannot replace managed JAR names. A Paper
version change requires a new compatibility review and matching asset pins.

## Pregeneration and borders

[Chunky 1.5.3](https://hangar.papermc.io/pop4959/Chunky/versions/1.5.3) is
installed on Paper, with its configuration and saved task state in
`plugins/Chunky`, included in clean-stop backups. The pinned JAR bundles its
dependencies and has no runtime downloader/updater. Backend bStats is disabled.
No task starts automatically; `continue-on-restart=false` means a saved task
also requires an explicit `chunky continue` after a wake/restart.

**ChunkyBorder is deferred:** its published
[Paper 1.2.23 release](https://modrinth.com/plugin/chunkyborder/version/asaBBItO)
declares support through 26.2, with no verified 26.3 release on 2026-10-09.
Finn chose to wait for verified compatibility. No custom border is installed,
set, resized or enforced. Pregeneration alone does not limit exploration.

Wake Paper by joining first. Keep someone connected throughout a long task:
the existing wake-once marker only starts Paper, and neither console commands
nor Chunky activity prevent lazymc's 15-minute empty-server sleep. There is no
declarative maintenance keep-awake control in the current runtime. Do not
disable the clean-stop guard or rely on a status ping to hold Paper awake.

For example, Finn can run these in the Survival dashboard console, choosing
the radius deliberately (1000 below is only an example, not configuration):

```text
chunky world world
chunky shape square
chunky center 0 0
chunky radius 1000
chunky selection
chunky start
chunky progress
```

Use `chunky pause` before leaving or a maintenance stop; use `chunky continue`
after joining again. Choose other dimensions explicitly rather than starting
parallel tasks by default. Do not run `chunky trim` for ordinary pregeneration:
it deletes terrain outside the selection. Finn's existing administrator
permissions cover Chunky; friends do not receive generation/admin commands.

BlueMap will discover and render the newly generated chunks afterwards. Its
existing player-present pause means it renders when the connected player
leaves, during the empty-but-awake window, and can need several wake windows
for a large area. Pregeneration does not force a full map render or change the
existing CPU, memory or idle-sleep budgets.

## World datapacks and game rules

The separate dashboard **Datapacks** list shows the following installed set,
plus the generated Survival World Policy pack. Installation status describes
the declaration; it does not assert that Paper is awake or a player's HUD is on.

| Vanilla Tweaks pack   | Pinned version | Minecraft / format |
| --------------------- | -------------- | ------------------ |
| Confetti Creepers     | 2.2.19         | 26.3 / 121.0       |
| Player Head Drops     | 1.1.18         | 26.3 / 121.0       |
| Mini Blocks           | 1.1.8          | 26.3 / 121.0       |
| More Mob Heads        | 2.20.1         | 26.3 / 121.0       |
| Custom Nether Portals | 2.3.21         | 26.3 / 121.0       |
| Double Shulker Shells | 1.3.18         | 26.3 / 121.0       |
| AFK Display           | 1.1.18         | 26.3 / 121.0       |

Coordinates HUD, Silence Mobs, Durability Ping and Armor Statues are no longer
managed. The next stopped-server reconcile removes their four previously
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
All seven declare `[121,0]` as both minimum and maximum format. Their bytes
and metadata are unchanged; the outer bundle is unwrapped before importing.

This public repository contains metadata and attribution only, with no
Vanilla Tweaks archive bytes. Each `pkgs.requireFile` input has a flat
SHA-256 hash and a canonical basename. Missing inputs fail the build with the
exact import command, rather than downloading anything. Neither runtime nor
build-time code contacts the pack builder. Future updates require obtaining
and reviewing new official files and hashes. Vanilla Tweaks attribution stays
in `credits.txt`. The packs remain subject to the
[Vanilla Tweaks terms](https://vanillatweaks.net/terms/); obtain them separately
from the official picker. Archives must not be committed here or added to
nix-secrets. The repository's unfree allowance covers only these seven manual
inputs.

### PaperTweaks evaluation (2026-10-10)

**Keep all seven official Vanilla Tweaks packs and the local Survival World
Policy pack.** PaperTweaks is maintained and now publishes 26.3 metadata, but
does not cover this installed set. No PaperTweaks JAR or permissions are added,
and no datapacks or world state are removed by this evaluation. The inventory
above is the repository's declaration; this audit did not inspect the live
server or enumerate unmanaged packs there. All seven official ZIPs in the local
Nix store were inspected and matched the SHA-256 values in `sources.json`.

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

| Current pack / behavior                                                                     | PaperTweaks module and enablement key                    | Coverage                                                                                                                                                                                |
| ------------------------------------------------------------------------------------------- | -------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Confetti Creepers: default 100% confetti; sets explosion radius to zero                     | `ConfettiCreepers` / `experimental.confetti-creepers`    | Similar outcome; plugin cancels the explosion and replaces the creeper with a firework. Firework damage and charged-creeper settings need comparison.                                   |
| Player Head Drops: head drops on PvP kills                                                  | `PlayerHeadDrops` / `items.player-head-drops`            | Supports player-kill requirement and drop chance.                                                                                                                                       |
| Mini Blocks: 209 stonecutter recipes producing textured heads                               | None                                                     | `WanderingTrades` / `hermitcraft.wandering-trades` adds trader offers, not these recipes or their acquisition mechanics.                                                                |
| More Mob Heads: mob-specific head loot and conditions                                       | `MoreMobHeads` / `mobs.more-mob-heads`                   | Deprecated; the module explicitly recommends the official datapack for improved functionality without a performance hit.                                                                |
| Custom Nether Portals: nonrectangular/crying-obsidian frames; 10–84 frame blocks            | `CustomNetherPortals` / `survival.custom-nether-portals` | Supports custom shapes/materials, but config limits portal interior size, width and height rather than the pack's frame-block count.                                                    |
| Double Shulker Shells: two shells per shulker, alongside head loot                          | None                                                     | Retain the loot-table datapack; an old wiki module listing does not establish current support.                                                                                          |
| AFK Display: 150-second position samples; gray team; movement checks every second while AFK | `AFKDisplay` / `survival.afk-display`                    | Plugin defaults to 300 seconds, checks block-position inactivity each second, colors display/tab names directly, and clears AFK on a player-move event. Timing and presentation differ. |
| Survival World Policy: reapplies 50% sleeping on world load                                 | Local pack                                               | Retain; do not enable a second sleep implementation.                                                                                                                                    |

Module names, configuration keys and behavior above are from the
[reviewed source tree](https://github.com/MC-Machinations/PaperTweaks/tree/b6e68bd1c3009d136ec0fc460486af567550bf90/src/main/java/me/machinemaker/papertweaks/modules).
In particular,
[MoreMobHeads' lifecycle](https://github.com/MC-Machinations/PaperTweaks/blob/b6e68bd1c3009d136ec0fc460486af567550bf90/src/main/java/me/machinemaker/papertweaks/modules/mobs/moremobheads/Lifecycle.java)
asks operators to disable that module in favor of Vanilla Tweaks. Thus even
a verified 26.3 release cannot replace all seven packs. Keeping the current
set preserves recipes, drops and gameplay without adding another plugin.
A partial switch of the four matching modules is a possible future task,
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
must grant default players the behavior nodes `vanillatweaks.playerheaddrops`
and `vanillatweaks.afkdisplay`, plus public information commands only where
needed; the four matching modules have no equivalent player-toggle commands
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

Keeping this set requires no cleanup. Removing its ZIPs alone would stop
loading their functions, recipes and loot tables but would not uninstall the
state they created. The current reconciler only removes ledger-owned archive
bytes; it never edits scoreboards, entities, items, advancements or world NBT.
The following inventory comes from the exact pinned official ZIPs:

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
mv 'afk display v1.1.18 (MC 26.3).zip' afk-display-1.1.18-mc26.3.zip
nix-store --add-fixed sha256 ./confetti-creepers-2.2.19-mc26.3.zip
nix-store --add-fixed sha256 ./player-head-drops-1.1.18-mc26.3.zip
nix-store --add-fixed sha256 ./mini-blocks-1.1.8-mc26.3.zip
nix-store --add-fixed sha256 ./more-mob-heads-2.20.1-mc26.3.zip
nix-store --add-fixed sha256 ./custom-nether-portals-2.3.21-mc26.3.zip
nix-store --add-fixed sha256 ./double-shulker-shells-1.3.18-mc26.3.zip
nix-store --add-fixed sha256 ./afk-display-1.1.18-mc26.3.zip
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

Repeat for all seven, keeping that root directory at its original path. This
worktree's `.gcroots/` is ignored by git; deleting the worktree removes those
local roots. On link, `system.extraDependencies` retains all seven ZIPs in the
installed system closure, rooted by the system profile and its retained
generations, even while Paper sleeps. Merely evaluating or building with
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

AFK Display samples position every 150 seconds, places stationary players in
the gray `afkDis.afk` scoreboard team and checks movement every second while
AFK. It does not detect chat, looking around or inventory activity. Joining
that team replaces previous team membership; leaving AFK clears it rather
than restoring the previous team. Other plugins/datapacks that assign teams,
name colors, tab-list formatting or scoreboard presentation can conflict.
This display does not exempt players from sleeping or lazymc's online count.

None of the seven requires an additional Java resource pack: mini blocks and
heads use vanilla player-head profiles, and confetti uses vanilla fireworks.
Normal client skin-texture requests are separate from downloading pack code.
[Bedrock/Geyser custom-head limitations](https://geysermc.org/wiki/geyser/custom-skulls/)
apply to Mini Blocks, More Mob Heads and Player Head Drops: placed heads can
use Geyser's existing rendering, but correct inventory/held/worn textures
require explicit skull mappings and Geyser's generated Bedrock resource pack.
Those mappings are not added by this change. AFK membership is server-side;
verify gray names, tab-list display and scoreboard/team interactions on Java
and Geyser clients after a future authorized deployment. Paper smoke tests
cannot establish client presentation parity.

The installer writes stable `infra-*.zip` names into `world/datapacks/` as the
Minecraft unit user, after `games-prechange`, upstream server preparation and
`games-prepare`, before lazymc can start Paper. It copies archive bytes, so world
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
`playersSleepingPercentage`) after the world loads on every Paper wake and
`/reload`. Minecraft owns the resulting `level.dat` persistence; Nix never
patches NBT directly. A manual gamerule change is overridden on the next load.
The policy pack runs without a polling unit, extra wake or RCON credential.

## Sleep, map and resource budgets

Velocity answers pings while Paper sleeps. BlueMap serves only static files
through the existing Cloudflare tunnel/service-publication framework at
`https://map.finnrut.is`; its origin is loopback nginx port 8766. Access bypass
is justified by the intentionally public, read-only map. nginx permits GET and
HEAD, rejects private dotfiles and directory indexes, and has read access to
only the web subtree. BlueMap's embedded webserver and live markers are off.
The map contains world terrain/builds and is public.

BlueMap renders to `plugins/BlueMap/web/maps` using file storage and client-side
compression handling. A single low-priority render thread runs while Paper is
awake and empty, with a 60-second update cooldown. Rendering pauses with any
player online and stops when lazymc sleeps after its existing 15-minute idle
period. No timer wakes Paper to render; large new areas can take several idle
windows. Wake the server once and allow its initial render before expecting a
working public map. Previously rendered tiles remain viewable during sleep.

The exact vanilla 26.3 client asset JAR is preseeded through Nix with downloads
disabled. BlueMap may still request Mojang version metadata; cached assets let
it recover if that metadata request fails. Its flow-math library is pinned and
bundled at build time, removing Paper's runtime library download declaration.
Skin downloads and BlueMap telemetry are disabled.

Paper retains `-Xms1G -Xmx4G` and MemoryMax 6G; Velocity retains a 512M maximum
heap and MemoryMax 1G. With vane deferred, these are conservative initial
budgets, not measured capacity guarantees. Monitor the existing games memory
panels, wake duration and BlueMap queue after deployment before increasing
concurrency or memory. Rendering can still consume one CPU core and write many
tiles; low thread priority and pausing while occupied protect gameplay. The
existing games slice CPU/IO accounting and weights remain in effect. Avoid a
whole-Paper CPU quota that would throttle its tick thread.

The 300-second Paper startup timeout, 25-second held join and existing clean
stop limits remain unchanged. A cold first wake can require a client retry;
there are no new network dependency downloads on that path. Use Paper's
[bundled spark](https://docs.papermc.io/paper/profiling/) when investigating slow
wakes or ticks; no duplicate profiler is installed.

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
Permissions load from the shared database when Paper wakes.

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
its separate reload command. Bukkit/Velocity op accounts retain upstream op
permissions independently of the LuckPerms groups.

The pinned Paper and Velocity **5.5.71** jars have identical import classes
(their SHA-256 hashes match `minecraft-plugin-artifacts.nix`).
[`ImportCommand`](https://github.com/LuckPerms/LuckPerms/blob/master/common/src/main/java/me/lucko/luckperms/common/commands/misc/ImportCommand.java)
reads local files as **gzip-compressed UTF-8 JSON**, regardless of filename.
Files must be readable directly inside the plugin directory; subdirectories and
`config.yml` are rejected. It only tries appending `.json.gz` when the requested
file does not exist and its name contains no dot. Use the full
`bootstrap.json.gz` name; `bootstrap.json` is not an alias. Template preparation
copies the gzip bytes atomically as the Minecraft owner with mode `0600`.

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
`https://map.finnrut.is/packs/` even while Paper sleeps. Declining the required
pack, or failing to download it, prevents a Java player from joining.

LuckPerms prefixes contain MiniMessage translation components with explicit text
fallbacks and rank-name hover tooltips. The pack translates `infra.rank.mod`,
`infra.rank.admin`, and `infra.rank.builder` to U+E100, U+E101, and U+E102 in the
default font. Without those translations, clients display colored `[Mod]`,
`[Admin]`, or `[Builder]` labels. Bedrock intentionally uses these labels: no
Bedrock font pack is installed. Pinned Geyser 2.11.3 build 1249 acknowledges
required Java packs without downloading them and honors component fallbacks.
Changing that pin must preserve both behaviors. Hover tooltips are a Java feature.

Chat consumes `<luckperms_prefix>` and `chat_color` metadata. The concurrent
`mc-tab-menu` implementation consumes the same prefix through
`%luckperms-prefix%` with MiniMessage enabled; its component transport must retain
the translation and fallback until delivery. There is no separate tab badge
palette. Discord webhook chat uses usernames and message bodies only, so rank
glyphs do not enter Discord-bound formatting.

Deploying updated files does not reconcile LuckPerms' PostgreSQL nodes. For the
declared groups/users, apply the new prefixes with the existing approved
replacement import after Paper wakes:

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

The BlueMap hook publishes **public** homes and warps as marker sets.
`/edithome <name> privacy public` publishes a home; `privacy private` hides it.
The home delimiter is `:` instead of `.` because Floodgate names start with
`.`: e.g. `/phome .BedrockFriend:base`. Private homes stay private. Publishing
exposes the name/location on the public map at `map.finnrut.is`; live player
markers stay disabled. BlueMap writes marker sets every 30 seconds while Paper
is awake. HuskHomes clears its marker sets when disabled, so home/warp markers
can disappear during lazymc sleep; they repopulate on wake. The static terrain
map remains viewable throughout. Admins create warps with `/setwarp <name>`;
regular friends can list/use them.

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
directions; publish/hide a BlueMap home and test a warp. For graves, die with
items/XP, deny another friend's access, recover as owner/mod, then cleanly stop
and wake Paper and recover a still-filled grave. These are operator smoke tests;
the Nix checks do not claim a live client integration test.

Mutable backend plugin directories are included with world snapshot roots in
the existing clean-stop backup. JAR/cache symlinks do not replace the pinned
Nix artifacts. Initial plugin/asset directories can make the existing guard
conservatively require a verified Paper shutdown before a snapshot: wake and
cleanly stop Paper once rather than bypassing that guard. Neither `runtime.py`
nor `tmodloader.nix` is changed by this feature.

The existing server backup additionally covers proxy SkinsRestorer/LuckPerms
state and an atomic PostgreSQL custom-format dump under
`/var/backup/games-luckperms`. That shared/proxy backup is separate from the
world's clean-stop snapshot; there is no cross-service point-in-time guarantee.
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
clients cannot use that Java mod. Joining Minecraft wakes Paper; UDP voice
packets alone do not.

## Discord operator steps

Classic DiscordSRV is chosen over [Ascension](https://github.com/DiscordSRV/Ascension):
classic has a released 26.3 build, while no suitable published Ascension release
was verified. Ascension's proxy architecture could keep a bot connected during
sleep, but death/advancement events would still need a backend integration.
Classic disconnects while Paper sleeps, announces that Survival is resting, and
reconnects after a Minecraft join wakes it. Discord messages during sleep are
not queued and do not wake Paper. This is the accepted tradeoff.

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

| Option             | Discord ID            | Purpose                                          |
| ------------------ | --------------------- | ------------------------------------------------ |
| `guildId`          | `1518484285466873997` | Guild owning the channels                        |
| `channelId`        | `1557960229528797265` | Main bidirectional chat, deaths and advancements |
| `eventsChannelId`  | `1518484285982769204` | Join, first join and leave messages              |
| `consoleChannelId` | `1557960243101831168` | Private Paper logs and diagnostic commands       |
| `roles.mod`        | `1558172717218533468` | LuckPerms `mod` → Discord Mod (purple)           |
| `roles.admin`      | `1558173111931904092` | LuckPerms `admin` → Discord Admin (green)        |

The defaults for other servers are empty. Either missing guild/chat ID, missing token or `enable = false`
means no DiscordSRV JAR is installed; Minecraft itself remains independently
gated by its existing mandatory credentials. The guild ID documents the guild
owning the selected channel; DiscordSRV resolves that guild from the channel.
Use Discord Developer Mode to copy the IDs and ensure the bot is in that guild.
An empty events ID keeps join/leave messages in chat; an empty console ID
disables console forwarding without disabling the bridge.

The pinned 1.30.5 JAR's `config/en.yml`, `messages/en.yml` and
`synchronization/en.yml` were inspected.
Routing uses `Channels.global`, `Channels.join` and `Channels.leave`; the message
templates have no channel selector. Deaths and advancements use distinct
`deaths`/`awards` routes and fall back to the first channel, `global`, here.
Server startup/shutdown messages also remain in chat.

Enable **Message Content** and **Server Members** privileged intents. Grant
**View Channel**, **Send Messages**, **Read Message History** and **Embed Links**
in the chat and events channels. Make the events channel read-only to ordinary
members so it remains a bot event feed. Grant the bot **Manage Roles** for rank
synchronization; its invite permission bit is `268435456` (OR it with the
existing permission integer when updating an invite). No Administrator
permission is needed. Presence is disabled. Webhooks, chat-channel console
commands, topic edits, nickname/ban synchronization and mandatory account
linking remain disabled. Join/leave, first join,
death, advancement and bidirectional chat messages are enabled. Test them after
the first configured wake. Confirm token permissions remain private and neither
configuration nor logs expose it.

Create Discord roles **Mod (purple)** and **Admin (green)**. Colours are set in
Discord's role editor, not by DiscordSRV. Put Admin above Mod and the bot's own
role **above both** in the role list; Manage Roles cannot manage roles at or
above the bot's role. Enable **Developer Mode**, right-click each role and
select **Copy Role ID**. Set those IDs in Survival's
`gameServers.servers.survival.minecraft.discord.roles.mod` and `.roles.admin`
declaration. These options default to empty on other servers. Only nonempty
IDs are mapped; with neither set, linking remains available but rank sync is
inert and Vault is not installed. Missing token/guild/chat IDs or a disabled
bridge still prevent DiscordSRV and Vault installation.

Players link voluntarily: run **`/discord link` in Minecraft**, then **DM the
displayed code to the bot** from the Discord account they want to link. Paper
must be awake for the bot to receive it. `/discord linked` checks the result.
Names are never used to auto-link accounts. Redeeming a new code cannot
automatically replace an existing link. Linking executes no console commands
and grants no separate "Linked" role. Unlinked players may still play and chat;
they simply do not receive synced roles. Mandatory linking is a separate,
future change.

Unlinking requires operator permission by default (`discordsrv.unlink`);
players should ask an operator to unlink their account before changing it.

LuckPerms group membership is authoritative. Both
`GroupRoleSynchronizationMinecraftIsAuthoritative = true` and
`GroupRoleSynchronizationOneWay = true` are required for **Minecraft → Discord
only**. `default` is never mapped. All memberships, including inherited groups,
count: an admin inherits mod and receives both roles when both IDs are set.
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

After deployment, test with a linked account: grant/remove `mod` and `admin`
in LuckPerms and confirm the corresponding Discord roles follow (including
inherited Mod for Admin). Grant a mapped role directly in Discord to a linked
default player and confirm LuckPerms stays default; the role should disappear
on resync. Check that removing a Discord role does not demote Minecraft, that
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
these logs as private. Forwarding and diagnostics stop while Paper sleeps, and
Discord commands cannot wake Paper.

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

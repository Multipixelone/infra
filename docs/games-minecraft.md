# Minecraft survival on link

Dawarich now uses `https://dawarich.finnrut.is`. Update the location-upload
app's server URL to that hostname. `map.finnrut.is` is reserved for BlueMap;
there is no redirect from that name to Dawarich and no data migration.

## Installed set and compatibility

Verified on 2026-10-08. Every release JAR uses an exact URL and SHA-256 in
`minecraft-plugin-artifacts.nix`; downloads were hashed before pinning. No
plugin JAR is fetched or updated at runtime. Configurations use Nix formats.

| Plugin | Version / placement | Evidence |
| --- | --- | --- |
| SkinsRestorer | 15.12.6 / Velocity and Paper | [26.3 fixes](https://github.com/SkinsRestorer/SkinsRestorer/releases/tag/15.12.6); [release source targets Velocity 4.2.0](https://github.com/SkinsRestorer/SkinsRestorer/blob/15.12.6/gradle/libs.versions.toml) |
| MiniMOTD | 2.2.5 / Velocity | [Release](https://github.com/jpenilla/MiniMOTD/releases/tag/v2.2.5); [source](https://github.com/jpenilla/MiniMOTD/tree/v2.2.5/platform/velocity) ping, command and favicon calls inspected against the pinned Velocity 4.2.0 build 30 API |
| BlueMap | 5.28 / Paper | [Explicit Paper 26.3 support](https://github.com/BlueMap-Minecraft/BlueMap/releases/tag/v5.28) |
| LuckPerms | 5.5.71 / Velocity and Paper | [Paper 26.3 release](https://modrinth.com/plugin/luckperms/version/v5.5.71-bukkit), [Velocity release](https://modrinth.com/plugin/luckperms/version/v5.5.71-velocity); Finn explicitly approved Velocity compatibility |
| Simple Voice Chat | bukkit-2.6.24 / Paper | [26.3 release](https://hangar.papermc.io/henkelmax/SimpleVoiceChat/versions/bukkit-2.6.24) |
| TickScope | 2.0.1 / Paper | [Maintained release](https://github.com/gzimbric/TickScope/releases/tag/v2.0.1), [26.3 compatibility](https://hangar.papermc.io/gzimbric/TickScope/versions/2.0.1) |
| DiscordSRV classic | 1.30.5 / Paper | [26.3 release](https://modrinth.com/plugin/discordsrv/version/1.30.5) |

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

A generated `bootstrap.json` declares `default` (skin and voice commands) and
`admin` (inherits default with administrator permissions). After the first
wake, run `lp import bootstrap.json` in the Paper console **once**, then verify
both platforms see the groups. The repo does not know Finn's verified MC UUID.
Set `gameServers.minecraft.adminUuid` to that UUID before importing to declare
his membership; the default is `null`, with no invented account. Do not
re-import casually after interactive permission changes: it is a bootstrap,
not an ongoing database reconciliation service.

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

| Option | Discord ID | Purpose |
| --- | --- | --- |
| `guildId` | `1518484285466873997` | Guild owning the channels |
| `channelId` | `1557960229528797265` | Main bidirectional chat, deaths and advancements |
| `eventsChannelId` | `1518484285982769204` | Join, first join and leave messages |
| `consoleChannelId` | `1557960243101831168` | Private Paper logs and diagnostic commands |

The defaults for other servers are empty. Either missing guild/chat ID, missing token or `enable = false`
means no DiscordSRV JAR is installed; Minecraft itself remains independently
gated by its existing mandatory credentials. The guild ID documents the guild
owning the selected channel; DiscordSRV resolves that guild from the channel.
Use Discord Developer Mode to copy the IDs and ensure the bot is in that guild.
An empty events ID keeps join/leave messages in chat; an empty console ID
disables console forwarding without disabling the bridge.

The pinned 1.30.5 JAR's `config/en.yml` and `messages/en.yml` were inspected.
Routing uses `Channels.global`, `Channels.join` and `Channels.leave`; the message
templates have no channel selector. Deaths and advancements use distinct
`deaths`/`awards` routes and fall back to the first channel, `global`, here.
Server startup/shutdown messages also remain in chat.

Enable **Message Content** and **Server Members** privileged intents. Grant
**View Channel**, **Send Messages**, **Read Message History** and **Embed Links**
in the chat and events channels. Make the events channel read-only to ordinary
members so it remains a bot event feed. Presence is disabled. Webhooks, chat-channel console commands, topic edits,
role/nickname/ban synchronization and mandatory account linking are disabled;
no Administrator or Manage Roles permission is needed. Join/leave, first join,
death, advancement and bidirectional chat messages are enabled. Test them after
the first configured wake. Confirm token permissions remain private and neither
configuration nor logs expose it.

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

| Candidate | Release / compatibility | Storage, features and performance considerations |
| --- | --- | --- |
| [CoreProtect CE](https://www.spigotmc.org/resources/coreprotect-community-edition.8631/) | 24.1; maintained, published support through 26.2 | SQLite/MySQL; mature inspect/lookup/rollback/restore with queued logging; no PostgreSQL |
| [CoreProtect paid](https://www.patreon.com/cw/coreprotect/sitemap) | 25.0 supports 26.3; paid artifact unavailable here | Adds DuckDB/ClickHouse; [native memory, thread and driver budgets](https://docs.coreprotect.net/config/) need attention; no PostgreSQL |
| [Prism](https://github.com/prism/prism/releases/tag/v4.4) | 4.4; maintained, released support through 26.2 | H2/SQLite/PostgreSQL/MySQL/MariaDB; inspect, rollback preview, restore and undo; streamed/batched operations bound work |
| [Original LogBlock](https://github.com/LogBlock/LogBlock) | No verified 26.3 release | MySQL; inspect/lookup/rollback and queued writes, but adds another database engine here |
| [Tracel](https://hangar.papermc.io/arnodoelinger/Tracel/versions/1.0.0-preview.1) | 1.0.0-preview.1 lists 26.3; first preview released today | Compact custom storage, inspect, preview/undo and crash-resumable rollback; very little release history |
| [Spyglass](https://github.com/firestarter/spyglass) | Preview, no verified 26.3 release | SQLite or external databases, extensive audit/rollback; aimed at larger servers and not the default for this small survival server |

Prism is the preferred future fit once it publishes verified 26.3 support. Its
PostgreSQL backend can reuse link's existing operations and avoid embedded-file
contention for concurrent history queries. Benchmark bounded queues/rollback
batches on link and verify shutdown flush/WAL behavior before enabling it. No
rollback database or speculative plugin is provisioned now.

# Games dashboard handoff

The backend and dashboard publication are declarative. The current UI is packaged
for `https://games.nyc.finnrut.is`; Finn designs the real UI later in an attended
session. Its only operator is Finn. Do not add server creation, package installation, configuration
editors, or secret editors to the dashboard. New Nix declarations appear through
the manifest automatically.

## Dev loop

The dashboard lives in `pkgs/games-dashboard/`: Python/FastAPI in `backend/`
and Vite/Svelte/TypeScript in `frontend/`. From the infra worktree root:

```console
just games-dashboard-dev
```

Open `http://127.0.0.1:5173`. The recipe runs Uvicorn with source reload and Vite
with HMR directly against the checkout; Ctrl-C stops both. The launcher installs
frontend dependencies automatically when `node_modules` or its installed lockfile
is missing, or the committed lockfile is newer than the installed lockfile.
Repeated starts skip installation while dependencies are current. Use
`just games-dashboard-shell` to enter the development shell and
`just games-dashboard-npm` to explicitly reinstall frontend dependencies.
Python, Node, and npm come from the locked flake; frontend packages are pinned in
`package-lock.json`.
Do not install Python dependencies globally or create a separate environment.

Both listeners bind only `127.0.0.1`. `PORT` sets the Vite port (default `5173`,
allowed range `1024`–`65534`); Uvicorn uses `PORT + 1`. Vite fails if its port is
occupied and proxies `/api` unchanged to Uvicorn, including SSE. For example,
`PORT=5200 just games-dashboard-dev` exposes only the frontend on port 5200.

`GAMES_DASHBOARD_MOCK=1` is the recipe default. The fixture comes directly from
the real schema-v1 Nix manifest evaluation used by `games-contract`, with its
evaluation-only prerequisites and backups enabled. No production secrets are
read or installed. The page lists server status and streams fake console lines.
Mock start/restart arms Minecraft's sleeping listener or starts Terraria; stop
stops the selected server. Backup records a fake completion and preserves the
server state. Backend reload/restart resets all in-memory mock state.

The API is `GET /api/servers` (manifest metadata with a `status` on each server),
`GET /api/servers/{id}/events` (SSE `log` events containing `id`, `timestamp`, and
`line`), and `POST /api/servers/{id}/{start,stop,restart,backup}` (returns `id`,
`action`, and `status`). Shared-service metadata is retained, but the dashboard
does not control Velocity or submit console commands.

Later, on a host with the installed game helpers and manifest, use:

```console
GAMES_DASHBOARD_MOCK=0 just games-dashboard-dev
```

Real mode reads only `/etc/games/manifest.json` and invokes the existing helpers
and manifest-listed systemd units with fixed argv. Missing/invalid manifests
fail startup; it never falls back to mock data. Run the backend with the existing
`games-dashboard` user's helper and polkit permissions for real actions; the
recipe grants no privileges and uses no sudo for service controls. Ordinary
developer users may be refused. Real actions can affect live servers and backups;
the real-mode adapter tests substitute a runner and never execute host controls.
Keep the development launcher on loopback. The packaged service uses the
registry's private LAN/VPN publication described below, with no login required.

For a quick check inside the shell:

```console
pytest -c pkgs/games-dashboard/backend/pyproject.toml pkgs/games-dashboard/backend/tests
npm --prefix pkgs/games-dashboard/frontend run check
npm --prefix pkgs/games-dashboard/frontend run build
python pkgs/games-dashboard/backend/tests/smoke.py
```

The smoke runs the actual dev recipe, checks the API and multiple SSE events
through Vite, then checks listener cleanup after Ctrl-C. It requires free ports
and installed npm dependencies. Follow the repository's `agent-run-long`
workflow for agent-run validation. Backend parity tests validate the generated
Nix manifest with strict nested models and require an exact JSON round-trip.

## Dashboard UI

The initial UI is implemented in the existing Svelte frontend. It uses the
paper/ink colors and local serif/monospace font families from
`modules/link/homepage-theme.css`; light/dark preference is saved locally.
`src/dashboard.css` owns the dashboard styles, `src/dashboard.ts` validates
schema-v1 responses and supplies status labels, and `src/Icon.svelte` supplies
SVG icons, including the server selector's chevron.

This is a personal admin tool. Keep labels terse and operational; do not add
taglines, introductory copy, decorative footers, or explanations of obvious
controls. The compact header leads directly into a responsive server selector,
the selected server's controls, and logs. Preserve useful state/error information
and warnings about disruptive actions.

Implemented behavior:

- Manifest-only server discovery with status polling every five seconds after
  each request completes. Invalid or unsupported schemas and inventory errors
  disable controls until polling recovers.
- Server state, player count, wake-on-join and backup configuration, copyable
  connection addresses, and read-only service/data-path details. Unknown player
  counts remain unknown. Shared-service availability and backup configuration
  are not presented as runtime health or backup history.
- Start/stop/restart and manual backup actions. Stop, restart, and backup require
  confirmation describing player disconnection and relevant recovery behavior.
  Controls remain locked per server while its action runs, including when
  another server is selected. Late polls cannot overwrite an action result.
- SSE console output with filtering, pause/resume, local clearing, and optional
  follow scrolling. The UI retains 500 lines, bounds individual displayed lines,
  reconnects automatically, and closes the previous stream on server selection.
  Clearing or pausing affects only the local display, not host logs.

If an action loses its connection before a response arrives, its outcome is
unknown and that server remains locked in the current page. Check host logs for
completion before reloading. The API still needs operation-status tracking to
recover this state without operator intervention. Reloading also loses in-page
locks for ongoing actions; backend serialization remains authoritative.

The UI was checked in Chrome in light/dark themes and at a 390px viewport,
including server selection, details, console filtering and pause/resume,
confirmation dialogs, and mock start/stop/backup actions. Svelte checking and
the frontend production build pass. These checks do not validate live game
operations or deployment. Console command submission, Velocity controls,
backup history and operation-status tracking remain follow-up work. The packaged
service adds private publication and production Origin checks;
these do not change the development UI or grant new game permissions.

## Backend inventory and adding servers

`gameServers.servers` is the flake-level registry in `modules/games/registry.nix`.
The day-one IDs are `survival` (`minecraft-paper`) and `terraria`
(`terraria-tmodloader`). `gameServers.targetHost` defaults to `link`; individual
definitions inherit it. Minecraft backends and Velocity must move together in
v1. Changing the target schedules the same definitions on the new host; restoring
the world data, enrolling that host in agenix, and changing Fortigate's destination
are also necessary before starting it.

For another Paper server, add a registry entry with its display name, hostnames,
whitelist/ops UUID maps, and three unused loopback ports (`minecraft.proxyPort`,
`serverPort`, `rconPort`). Declare its RCON secret as described below. Hostnames,
Velocity routes, backups, manifest entries, and permission allowlists derive from
the registry. The default route is `gameServers.minecraft.defaultServer`.

Minecraft packages are selected by declared stable `minecraft.version` from the
locked nix-minecraft input. An explicit package override is available. Plugins
are Nix paths to hashed JAR artifacts. Terraria's image must include a digest;
`terraria.mods` maps internal mod names to pinned `.tmod` artifacts, and
`modConfigs` holds declarative JSON configuration. There are no automatic
Workshop downloads or runtime package updates. Another game gets an adapter in
`gameServers.adapters`, an option contribution, and an `infra.games.runtime`
projection following the existing adapters' contract.

The maintained input is [Infinidoge/nix-minecraft](https://github.com/Infinidoge/nix-minecraft);
the originally requested `Infinidim-Enterprises` repository does not exist.
Input follows are explicit.
Change `flake-file` declarations, then regenerate; never hand-edit `flake.nix`.

Day-one pins are Paper 26.3, Velocity 4.2.0 build 30, Geyser 2.11.3 build 1249,
Floodgate 2.2.5 build 141, and `jacobsmile/tmodloader1.4` 2026.08.3.0 by digest.
Velocity explicitly uses Java 25 because its upstream wrapper selects Java 21.
Floodgate account linking and metrics are disabled; Bedrock identities keep the
declared `.` prefix.
The container lacks ICU and its .NET installer fails. The adapter mounts the
three ICU libraries and a hashed, portable .NET 8.0.31 runtime with its exact
runtime configuration, all read-only. Startup works offline after pulling the
image. These dependency changes also require a pre-change snapshot. The pinned
container/runtime adapter currently supports x86_64 hosts.

## Manifest and status

Read `/etc/games/manifest.json`; it is Nix-generated, root-owned, and contains
no secret values. Schema version 1 has `host`, `sharedServices` (Velocity), and a
`servers` array. Each server contains:

| Field                          | Meaning                                                          |
| ------------------------------ | ---------------------------------------------------------------- |
| `id`, `game`, `displayName`    | Stable identity, adapter name, UI label                          |
| `public`                       | Array of `hostname`, `port`, `protocol`, and `edition` endpoints |
| `unit`, `container`            | Exact systemd unit; container name or null                       |
| `dataDir`, `worldPaths`        | Persistent data and backup paths; informational                  |
| `wakeOnJoin`                   | Whether start arms an idle wake listener                         |
| `available`                    | Required encrypted service secrets exist in the locked input     |
| `console`                      | Method, command argv, and local RCON details when applicable     |
| `backup`                       | Enabled flag, exact backup unit, and command argv                |
| `statusCommand`, `logsCommand` | Fixed helper argv                                                |

`available` describes configured prerequisites, not runtime health. Likewise,
`backup.enabled` means enabled in Nix with a declared password; NAS availability
is checked at runtime. Handle unknown future schema versions explicitly.

`games-status` prints a JSON array for all servers; `games-status survival` prints
the one-entry array. Entries contain `state` (`running`, `sleeping`, `stopped`),
`unitState`, `ready`, `playersOnline`, and `available`. Minecraft player counts
come from bounded RCON `list` requests. `null` means unavailable; never display
it as zero. Terraria has no cheap synchronous player query in this image, so
its count is null. Its `playing` console command writes its result to the live
journal; the attended dashboard may integrate that response with an explicit
timeout. Status polling does not trigger a Minecraft login or wake.

Survival's systemd unit supervises both lazymc and Paper. Starting that unit
normally arms wake-on-join and leaves Paper sleeping. A join wakes Paper;
15 minutes with no players stops it. Stopping the unit disables wake-on-join.
Velocity remains up. A cold startup longer than lazymc's 25-second hold requires
the player to reconnect; don't promise instant joins. Bedrock hostname forwarding
is automatic in the Velocity Geyser plugin.

## Controls, console, and live logs

The packaged dashboard runs as the existing `games-dashboard` system user.
Polkit allows that exact user to start/stop/restart only generated game units,
including Velocity, and to start only the fixed enabled backup units. There is
no grant for changing unit files, creating transient services, reloading systemd,
or managing other services. Use fixed argv and validate every ID against the
manifest before issuing an action.

For example, start or stop `minecraft-server-survival.service`; Terraria's unit
is `podman-games-terraria.service`. Use the manifest's names instead of deriving
them in application code.

`games-logs survival --follow` streams journald for that game and its backup
unit, with the last 200 lines initially. `games-logs terraria --follow` also
selects that container's journald messages; `games-logs velocity --follow`
shows proxy logs. The sudo-backed reader accepts only registered IDs and the
optional `--follow` flag. The dashboard user is not in `systemd-journal` and
cannot read the rest of the host's journals.

Use `games-console survival 'list'` or other RCON commands. The survival RCON
password is an agenix file readable by the Minecraft owner and the dashboard
group. The manifest supplies its path and `127.0.0.1:25575` endpoint. RCON is
never exposed publicly. Commands apply to a running Paper process; sleeping
servers have no RCON listener.

`games-console terraria 'playing'` injects a literal console command through a
fixed privileged helper. It returns command-submission status; responses appear
in journald. No Podman socket or group membership is granted. The proxy console
uses a fixed FIFO with symlink/type checks. Helpers reject extra arguments,
newlines and NULs, and do not evaluate command strings as shell code.

Console access is game-administrator authority: it can change a running world or
kick players. Keep it authenticated, audited and unavailable to other LAN users.
Nix resets declared roster/configuration on subsequent starts. Do not shell out
using a concatenated string. Serialize each server's dashboard operations and
disable its buttons until an action completes, including backup recovery.

## Backups and changes

Run `games-backup survival` or `games-backup terraria` for an attended snapshot.
This starts the fixed restic unit through polkit. It first verifies the initialized
repository and alexandria's actual NFS mount, then stops the server, verifies
graceful shutdown, snapshots its world paths and version metadata, and restores
its previous running/sleeping/stopped state. Active players are disconnected.
The Minecraft stop helper flushes saves through RCON before waiting for JVM exit.
Terraria must complete its save-and-exit sequence; a failed or forced stop is
not accepted as a consistent snapshot. Its stop helper sends literal `exit`,
waits for normal exit, checks fresh ordered save/validation/modded-save log
messages, and requires both world files' modification times to advance. The
image's exit code alone is insufficient: its wrapper can report success after
a runtime crash. Logs are retained at the server's `logs/server.log` beneath
its data directory and through journald.

Nightly jobs run at 00:30 for survival and 00:40 for Terraria, with at most two
minutes of jitter, before the 01:00–09:00 beets window. Retention is seven daily and
four weekly snapshots per server. Pruning is a separate unit, so a prune failure
does not misreport a successful snapshot as a failed backup. Failures use the
existing Telegram notification unit. The OneDrive jobs and batch slice budgets
are unchanged.

The repository is `/media/alexandria/Backups/games`, on the existing NFS export
`192.168.6.9:/volume1/homes/tunnel`. Its NAS path is
`/volume1/homes/tunnel/Backups/games`. The helper refuses an absent mount or a
different filesystem; it does not initialize a local substitute repository.

Backups default to disabled. Finn must create the password, arrange NAS write
permissions for the effective NFS identity, initialize the repository, and set
`gameServers.backup.enable = true`. Initialize it only with the NAS mounted:

```console
sudo restic -r /media/alexandria/Backups/games \
  -p /run/agenix/games/restic-password init
```

The server may create its first empty world before backups are configured.
Subsequent version/modpack changes require a successful snapshot before new
files can open that world. Existing worlds without a version baseline also
require a snapshot and verified clean shutdown. Failed units and absent or
failed save proofs are refused, including when the server is already stopped.
After an unclean exit, start the unchanged version and complete a clean stop
before changing versions. This guard fails closed while backups are disabled. Package
downgrades are changes too; a Nix rollback does not undo a world migration.

Version metadata and persistent `<id>-stop.json` save proofs live under root-only
`/srv/games/.state`. Starting a game clears its proof; its stop hook records a
successful save. Proofs survive reboot and cannot be written by the game user.
Paper uses nixpkgs lazymc 0.2.11 with a small patch that atomically records its
child's kernel exit result before returning to sleeping. Every wake invalidates
the previous result; a forced kill leaves it false. The root stop/post-stop hooks
also verify this result, so a sleeping listener cannot conceal a failed idle
shutdown. Normal idle RCON stops exit successfully; Java's normal signal exit
codes 130/143 retain upstream's graceful-shutdown interpretation. This local
patch changes no forwarding packets or wake logic.
World roots with symlinked ancestors are rejected. Backups include all
Paper dimensions and Terraria's `.wld`, `.twld`, and sidecar backups. Preserve
the private secrets separately; world snapshots do not replace agenix recovery.
For recovery, inspect restic snapshots tagged `games:survival` or
`games:terraria`, restore to a quarantine directory, stop the relevant unit,
then restore the world, matching version metadata, and save proof together. Never restore
over a live server. A failed backup attempts service recovery in `finally` and
again through systemd's stop-post hook. Backup units allow 40 minutes including
stop/recovery; a timeout has a separate six-minute recovery allowance.

## Secrets and first startup

Create encrypted files in Finn's separate `nix-secrets` repository, not this
worktree. Enroll link's host identity in each file's recipients; when moving,
enroll the destination before changing the target. Commit only encrypted files
there, then update this repo's `secrets` input lock. Decrypted files live beneath
`/run/agenix/games` and never enter the Nix store.

| Run `agenix -e` with this path            | Contents                            | Runtime access                  |
| ----------------------------------------- | ----------------------------------- | ------------------------------- |
| `games/minecraft/velocity-forwarding.age` | Random forwarding secret            | Minecraft, 0400                 |
| `games/minecraft/floodgate-key.age`       | Exact Floodgate-generated `key.pem` | Minecraft, 0400                 |
| `games/minecraft/survival-rcon.age`       | Random RCON password                | Minecraft/dashboard group, 0440 |
| `games/terraria/terraria-password.age`    | Server password                     | Root, 0400                      |
| `games/restic-password.age`               | Separate restic repository password | Root, 0400                      |

Password and forwarding payloads must be raw, single-line, 16–256 URL-safe
characters (`A–Z`, `a–z`, digits, `_`, `-`), not `NAME=value` environment files.
`openssl rand -hex 32` produces suitable values. Keep the Floodgate key's complete
original contents; it is a different format. Generate that key with Floodgate in
a temporary, isolated Velocity instance bound only to loopback, then encrypt it.
Do not generate or replace that authentication key automatically on each boot.

For each future Paper server `<id>`, create
`games/minecraft/<id>-rcon.age`; for another Terraria server, create
`games/terraria/<id>-password.age`. Missing encrypted files leave the affected
services disabled and the manifest present. No fake deployment secrets are used.
The checked-in `tests/fixture.age` is an evaluation fixture only and is never
selected by production configuration.

Fill the currently empty whitelist and ops maps with Java names/UUIDs or
Floodgate names/UUIDs. Bedrock names begin with `.`; obtain their Floodgate UUIDs
from trusted account data or the isolated proxy. The empty whitelist is enforced
and intentionally admits nobody. Ops currently receive level 4; declaring ops
does not replace the whitelist. Java authentication stays enabled on Velocity;
Paper's loopback-only backend disables its own online authentication and verifies
Velocity's modern forwarding secret instead.

## Game network and dashboard publication

### Homepage game tiles

Homepage's Games group is generated by `modules/games/homepage.nix` from the
registry-derived Link servers. Adding an enabled server with the required secret
files automatically adds its tile. Disabled servers, missing prerequisites, and
explicitly disabled service units have no tile, avoiding false outage indicators.
The existing theme and Dashboard Icons conventions apply to this group.

Minecraft widgets query each server's loopback lazymc listener, currently
`127.0.0.1:25566` for Survival, rather than Paper or the shared Velocity port.
Homepage uses an `udp://` URL convention but its Java Minecraft widget sends TCP
status requests. Status requests and echoed pings do not log in or wake Paper;
`games-lazymc` tests both repeated direct pings and the pinned Velocity proxy's
default and forced-host status replies before verifying the backend stayed asleep.
Velocity's default disabled ping passthrough returns proxy-wide players/version
and MOTD, so it does not describe an individual sleeping server.

Lazymc returns its sleeping MOTD when Paper is asleep and the backend status when
awake. Homepage's built-in Minecraft widget exposes only players, version, and
Up/Down, discarding MOTD: **Up includes sleeping**, and players are zero while
asleep. On the first cold start even the maximum player count may be zero until
lazymc learns it. The static tile description explains sleep; Minecraft's own
server list displays the sleeping MOTD. Tile descriptions list public join
hostnames, including both Survival aliases.

GameDig's Terraria support requires the TShock HTTP API, which tModLoader does
not provide. Instead, Homepage's `customapi` widget displays **TCP status** from
the read-only `games-homepage-status` systemd service. It binds
`127.0.0.1:18777`, checks only declared Terraria loopback ports (currently 7777),
sends no game payload, and grants no game controls or secret access. Up indicates
TCP reachability, not player counts or readiness. Its port is not opened in the
firewall or published through nginx.

**Games dashboard is always visible** and links to `https://games.nyc.finnrut.is`.
There is no enable switch: its packaging and LAN-only publication are being
completed separately. The tile uses the publication inventory's canonical URL
when the `games` application is registered, with the planned hostname as fallback;
any duplicate publication-generated tile is consolidated into this Games group.
Adding Homepage tiles alone does not package or publish the dashboard.

Finn manually adds these Fortigate forwards to link (`192.168.6.6`):

- 25565/TCP: Java through Velocity, `mc.finnrut.is` and `survival.mc.finnrut.is`.
- 19132/UDP: Bedrock through Geyser at the same hostnames.
- 7777/TCP: `terraria.finnrut.is:7777`.

Their unproxied A records are maintained by existing Cloudflare DDNS. Cloudflare
HTTP proxying cannot carry these game protocols. There are no SRV records because
Java uses its default 25565 port. Loopback-only survival ports are 25566 (lazymc),
25567 (Paper), and 25575 (RCON). No extra signaling port is enabled in Geyser.

**ATM10 remains excluded and `autoStart=false`.** Its existing host mapping still
claims 25565 if manually started, conflicting with Velocity. Don't start both;
the dashboard must not offer ATM10 as a managed server.

The dashboard is registered as `servicePublication.applications.games`, with
`site="nyc"`, `public=false`, and both backend and proxy on link. Its single-worker
Python/FastAPI process serves the API and the Nix-built Svelte assets on
`127.0.0.1:8780`. The listener has no LAN firewall opening. Blocky resolves
`games.nyc.finnrut.is` to link (`192.168.6.6`); generated nginx and link's SAN
certificate provide HTTPS. There is no public DNS, DDNS or Tunnel route for it.

**Private: LAN and VPN.** Finn approved using the registry's normal private-app
policy: `192.168.3.0/24`, `192.168.5.0/24`, `192.168.6.0/24`, and VPN
`10.100.0.0/24`. The routed `.7` and `.8` LANs are not accepted. nginx checks the
client source address and denies other ranges, including public clients. There
is no application-specific VPN deny or new shared access-policy hook.

Open `https://games.nyc.finnrut.is` from an accepted LAN or VPN client using
internal DNS. No login or Basic auth is required, matching the registry's other
private publications. The UI, API, controls, SSE and `/healthz` all use the same
private ACL. `/healthz` returns HTTP 200 with `{"status":"ok"}` after valid startup
and reveals no manifest or server status.
The health contract expects 200 within three seconds. nginx disables buffering,
caching and gzip for this application, limits request bodies to 4 KiB, and allows
45 minutes between upstream reads for long backups. The backend requires the
exact production Origin on control POSTs and rejects foreign API/SSE Origins;
no cross-origin CORS permissions are granted.

`systemd.services.games-dashboard` uses the existing dashboard identity and only
the existing status/log/backup helpers and polkit controls. Its filesystem is
read-only (`ProtectSystem=strict`), home directories are hidden, `/tmp` is private,
and network access is limited to loopback. Allowed address families are AF_UNIX
(systemd/journal IPC), AF_INET (HTTP/RCON), and AF_NETLINK (sudo audit support).
`NoNewPrivileges=false` is deliberate: the fixed `games-logs` wrapper needs
setuid sudo to run its restricted journal reader. The capability bounding set is
left at its default for that sudo path; no ambient capabilities, extra groups,
sudo commands or polkit grants are added. Optional `/run/sudo` and `/var/lib/sudo`
write exceptions preserve sudo's runtime state. Game data, journals, secrets and
the Nix store remain read-only. Console command submission remains outside the
dashboard API; the existing console helpers retain their own permissions.

The backend grants no access to restic credentials, Floodgate keys, forwarding
secrets, arbitrary journals or the container runtime socket.

### Enablement and activation

The dashboard unit is enabled unconditionally and starts without a dashboard
secret. Game servers still require their own secrets; missing game secrets do
not disable the dashboard. No activation or push is part of this change. Use the
normal publication workflow in `docs/service-publication-runbook.md` for a
separately authorized rollout; do not deploy a publication host through an
unrelated generic rebuild.

### Iterating on the UI

`just games-dashboard-dev` remains the source/HMR development loop, with mock
mode by default. It serves the checkout without affecting game servers. Edit the
frontend there for Finn's attended design session. The deployed service uses immutable assets from
`nix build .#games-dashboard`; checkout edits do not change it until rebuilt and
activated through the publication workflow. Never run Vite in production.

## Attended checks and remaining choices

- Supply the roster and secrets, configure/verify NAS permissions and test a
  snapshot plus quarantine restore before accepting protected updates.
- Confirm Java and authenticated Floodgate Bedrock joins through the proxy,
  whitelist rejection, forced-host routing, and sleep/wake behavior. Test a
  second hostname when adding another server.
- Confirm Fortigate forwards and LAN hairpin behavior for the public game names.
- Perform the separately authorized publication rollout. Verify LAN/VPN access
  without a login, public denial, private health, and streamed logs before live
  controls.
- Choose future Terraria mods and its player-list presentation. No mods are
  currently enabled, and size/difficulty apply only when creating a new world.
- Size memory after real play: Paper gets a 6G cap with 4G maximum heap, Velocity
  plus plugins 1G/512M heap, and tModLoader 4G. All belong to `games.slice` with
  CPUWeight 200, above the existing batch budget; backfill limits are untouched.

Development and fixture checks do not deploy, activate, or modify real worlds. Automated
fixture checks do not replace an authenticated client play test.

To repeat local validation, use the repository's `agent-run-long` workflow for
the exact link evaluation, new `games-contract`, `games-runtime`, and
`games-lazymc` checks, new game/helper package outputs, and the existing
service-publication checks. The runtime check includes an actual restic
snapshot/quarantine restore. The lazymc check exercises raw UUID and Floodgate
metadata preservation, modern forwarding request/response packets, cold/warm
joins, empty-server sleep, another wake, and forced-stop rejection against real
lazymc 0.2.11.

Dashboard publication checks are `games-dashboard-backend`,
`games-dashboard-publication` (actual nginx private ACL/origin/SSE fixture), and
`games-dashboard-service` (NixOS fixture exercising actual sudo-backed logs and
polkit controls inside the production sandbox). Build the `games-dashboard`
package explicitly. A separate local packaged smoke can run in the dev shell:

```console
python pkgs/games-dashboard/backend/tests/packaged_smoke.py --executable /nix/store/<built-games-dashboard>/bin/games-dashboard
```

The smoke is bounded to about 60 seconds, uses only mock data, verifies health,
inventory, static assets and multiple SSE events, and stops its listener. Agent
runs use `agent-run-long --label NAME --timeout 30m -- COMMAND…` with at least
60 seconds of outer timeout headroom; logs and synthetic fixtures stay under
`/tmp/opencode`. Neither mock smokes nor VM fixtures operate live game servers.

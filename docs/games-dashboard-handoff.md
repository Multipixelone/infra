# Games dashboard handoff

The backend is declarative; the dashboard is an attended follow-up. Its only
operator is Finn. Do not add server creation, package installation, configuration
editors, or secret editors to the dashboard. New Nix declarations appear through
the manifest automatically.

## Dev loop

The plain skeleton lives in `pkgs/games-dashboard/`: Python/FastAPI in `backend/`
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
`action`, and `status`). Shared-service metadata is retained, but the skeleton
does not control Velocity or submit console commands. The UI intentionally has
no controls or dashboard design yet.

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
Keep this unauthenticated skeleton on loopback. Authentication and publication
remain attended follow-up work.

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

Run the future dashboard as the existing `games-dashboard` system user.
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

## Network and later publication

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

For the dashboard, build on the Python/FastAPI and Svelte/TypeScript skeleton
with SSE. Package the eventual service separately, bind it to a loopback port, run it as
`games-dashboard`, and implement `/healthz` before publishing it. Required UI
features are status, players online, live console, start/stop, and back up now;
server discovery comes exclusively from the manifest.

No `games.nyc.finnrut.is` application is registered yet. In the attended session,
add `servicePublication.applications.games` with `site="nyc"`, `public=false`,
`routes.root.backend.host="link"`, the selected loopback backend port,
`routes.root.proxy.host="link"`, and health path `/healthz`, expected status 200,
timeout 3 seconds. Use the existing certificate, Blocky, nginx and publication
workflow in `docs/service-publication-runbook.md`; regenerate its outputs, run its
checks, and perform the separately attended rollout. Do not create a public
Tunnel route or DDNS record for this application.

Private publication currently trusts configured LAN **and VPN** client networks;
`public=false` alone does not meet this dashboard's LAN-only requirement. Before
publishing it, add a declarative application-specific client-network restriction
to the registry/proxy configuration, permit only the intended NYC LAN CIDRs,
and check that VPN and public clients are denied. Keep other applications' access
unchanged. Choose Finn-only application authentication (for example a passkey
session) and CSRF protection; LAN reachability alone is not identity. Restrict WebSocket/SSE
origins, bound command output and request sizes, avoid credentials in responses,
and require a session for every control action. The backend grants no access to
restic credentials, Floodgate keys, forwarding secrets, arbitrary journals or
the container runtime socket.

## Attended checks and remaining choices

- Supply the roster and secrets, configure/verify NAS permissions and test a
  snapshot plus quarantine restore before accepting protected updates.
- Confirm Java and authenticated Floodgate Bedrock joins through the proxy,
  whitelist rejection, forced-host routing, and sleep/wake behavior. Test a
  second hostname when adding another server.
- Confirm Fortigate forwards and LAN hairpin behavior for the public game names.
- Select the dashboard's authentication and backend port, and implement its
  application-specific LAN-only restriction before publication.
- Choose future Terraria mods and its player-list presentation. No mods are
  currently enabled, and size/difficulty apply only when creating a new world.
- Size memory after real play: Paper gets a 6G cap with 4G maximum heap, Velocity
  plus plugins 1G/512M heap, and tModLoader 4G. All belong to `games.slice` with
  CPUWeight 200, above the existing batch budget; backfill limits are untouched.

Implementation does not deploy, activate, push, or modify real worlds. Automated
fixture checks do not replace an authenticated client play test.

To repeat local validation, use the repository's `agent-run-long` workflow for
the exact link evaluation, new `games-contract`, `games-runtime`, and
`games-lazymc` checks, new game/helper package outputs, and the existing
service-publication checks. The runtime check includes an actual restic
snapshot/quarantine restore. The lazymc check exercises raw UUID and Floodgate
metadata preservation, modern forwarding request/response packets, cold/warm
joins, empty-server sleep, another wake, and forced-stop rejection against real
lazymc 0.2.11.

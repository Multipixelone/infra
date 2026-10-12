# Grimoire on Link

Grimoire replaces Kavita at `https://rpg.finnrut.is`. Nix manages the Podman
container, Link's nginx origin, publication registry and backup preparation.
Configuration alone does not publish or activate the service; the coordinated
human-gated launch described below is still required.

## Release and storage

The pinned image is `docker.io/hunterreadca/grimoire:1.8.0` (the OCR variant),
released on 2026-10-08. On 2026-10-12, Docker Hub and the registry confirmed:

- OCI index: `sha256:3c3bad0f15462538d3058d4d2b292a18d6487ee20a20a23718263d9f8ad6eb58`
- Linux amd64 manifest: `sha256:7a299c54cb51359ae81bc361363eb8738fdf35654cfa604efc5b31c046838549`
- Image configuration: `APP_VERSION=1.8.0`, TCP port 9481, uvicorn startup,
  and an unauthenticated `/api/health` container health check.

Primary references: [release](https://github.com/hunter-read/grimoire/releases/tag/v1.8.0),
[image tag metadata](https://hub.docker.com/v2/namespaces/hunterreadca/repositories/grimoire/tags/1.8.0),
[Dockerfile](https://github.com/hunter-read/grimoire/blob/v1.8.0/Dockerfile),
[configuration](https://github.com/hunter-read/grimoire/blob/v1.8.0/docs/configuration.md),
and [library structure](https://github.com/hunter-read/grimoire/blob/v1.8.0/docs/library-structure.md).

| Host path                          | Container path            | Contents                                                           |
| ---------------------------------- | ------------------------- | ------------------------------------------------------------------ |
| `/srv/grimoire/data`               | `/data`                   | SQLite database, accounts, campaigns, uploads, signing key, caches |
| `/srv/grimoire/library`            | `/library`                | Writable books, maps, tokens, audio and models                     |
| `/srv/kavita/library`              | `/library/books/Imported` | Existing library, reused in place as the Imported game system      |
| `/var/backup/grimoire/grimoire.db` | Not mounted               | Checked online SQLite snapshot for Restic                          |
| `/var/lib/kavita`                  | Not mounted               | Preserved former application state, also covered by Restic         |

The application runs as Link's existing `tunnel:users` UID/GID `1000:100`.
Data is mode `0700`; library ownership matches the existing `tunnel:users`
convention. The container has no host-network access, home-directory mount,
Docker socket or added capabilities. Its published port is IPv4 loopback only.

Kavita's dedicated port-5000 firewall declaration is removed. Link's existing
Shairport Sync service also uses port 5000 and retains its own opening.

The old library is not moved, copied, renamed or reorganized during activation.
Its existing nested folders appear as categories under Imported; root books
become core books. Admin-initiated file management can subsequently modify the
writable library. Kavita accounts, annotations and metadata are not imported.
Its encrypted credential source and application-state files remain untouched.

## Family access and first administrator

“Family permission is good” selects the existing Cloudflare Access `family`
policy, retaining its reviewed identities, US restriction and 24-hour session.
Grimoire has admin, GM, player and guest roles, with no upstream family role.
Cloudflare access does not create or elevate an application account. Password
authentication remains enabled; guest invite authentication is disabled.

Grimoire normally makes the first account an administrator. nginx permanently
returns 403 for `/api/auth/setup`, including access through the LAN vhost, so
claim the account directly through the loopback origin after approved activation.
On Link, open `http://127.0.0.1:9481`; from another machine, forward it:

```fish
ssh -N -L 19481:127.0.0.1:9481 tunnel@192.168.6.6
```

Open `http://127.0.0.1:19481` and create the parent-owned admin using credentials
chosen privately by the human. Then sign in again at the HTTPS URL: refresh
cookies are marked secure because `BASE_URL` is HTTPS. Create other accounts in
Settings → Users, normally as players; assign GM/admin roles deliberately.
There are no seeded accounts, placeholder passwords, OIDC mappings or Access
bypasses. See [upstream permissions](https://github.com/hunter-read/grimoire/blob/v1.8.0/docs/users-and-permissions.md).

`SECRET_KEY` is unset. Upstream generates `/data/secret_key` with private
permissions on first boot and reuses it on restart. One uvicorn worker avoids
competing first-run initialization. Never print or copy that file into source,
notes, logs or chat; Restic backs it up encrypted alongside the rest of the data.

## Online backups

The existing `restic-backups-srv` timer runs at 01:00 in the host timezone, with
up to 20 minutes of jitter and persistent catch-up. Its preparation hook runs
`grimoire-sqlite-backup` against the live database. The helper:

1. Opens the existing database read-only and uses SQLite's online backup API,
   including committed WAL contents, without stopping Grimoire.
2. Writes a private temporary file in root-owned `/var/backup/grimoire`, with a
   five-minute snapshot limit, and requires `PRAGMA integrity_check` to pass.
3. Publishes the standalone database atomically with mode `0600`. A missing,
   corrupt or failed source leaves the previous snapshot intact and fails the
   Restic unit, which uses the existing failure notification mechanism.

Restic includes that snapshot, both library directories, all persistent Grimoire
data and retained Kavita state. It excludes the live `grimoire.db`, its SQLite
side files, thumbnails and rendered-page cache. Accounts, campaigns, uploaded
files, character portraits, custom covers and the signing key are covered.
Concurrent asset/library edits may not exactly match the database snapshot;
this accepted tradeoff keeps the application available throughout backup.

The offsite destination is the existing encrypted OneDrive repository through
the existing agenix password and mutable rclone configuration. Retention is
14 daily, eight weekly, 12 monthly and five yearly snapshots; pruning is a
separate 03:00 job and repository checking runs monthly. The local database
file is a preparation artifact, not a second offsite copy. Confirm a successful
Restic snapshot before relying on this backup. The first run requires an
initialized, healthy application database.

Application backup scheduling is pinned off. The upstream manual ZIP backup
can still be used, but [its v1.8.0 implementation](https://github.com/hunter-read/grimoire/blob/v1.8.0/backend/services/backup/_archive.py)
omits the library, signing key and character portraits. Use the host Restic
snapshot for complete recovery.

Before an upgrade or destructive library operation, the human can request and
verify a fresh offsite backup after the service has been activated:

```fish
sudo systemctl start restic-backups-srv.service
systemctl status restic-backups-srv.service --no-pager
restic-onedrive snapshots --path /var/backup/grimoire
```

`restic-onedrive` supplies the existing repository and credential references;
do not read or export their contents. Application versions are changed in Nix,
with a newly verified digest, and activated through the human approval gate.
Upstream applies database migrations on startup. A code rollback after an
upgrade can require the matching pre-upgrade database backup as well.

## Restore from an offsite snapshot

These commands are for a human performing a separately authorized restore on
Link. Restic selection can be prepared while the app is running; replacing data
requires the container to be stopped. Review the chosen snapshot's timestamp
and run the same application version or a compatible newer version.

```fish
restic-onedrive snapshots --path /var/backup/grimoire
set restore_dir (sudo mktemp -d /var/tmp/grimoire-restore.XXXXXXXX)
set snapshot_id YOUR_SELECTED_SNAPSHOT_ID
restic-onedrive restore $snapshot_id --target $restore_dir \
    --include /var/backup/grimoire \
    --include /srv/grimoire/data \
    --include /srv/grimoire/library \
    --include /srv/kavita/library
sudo sqlite3 $restore_dir/var/backup/grimoire/grimoire.db 'PRAGMA integrity_check;'
```

Proceed only if integrity checking prints `ok` and the selected snapshot has
all expected library and asset directories. The live database was excluded
from Restic, so the database to restore is the one under `var/backup/grimoire`.
The restored signing key remains private; do not display it.

```fish
sudo systemctl stop podman-grimoire.service
set stamp (date -u +%Y%m%dT%H%M%SZ)
sudo mv /srv/grimoire/data /srv/grimoire/data.before-restore-$stamp
sudo mv /srv/grimoire/library /srv/grimoire/library.before-restore-$stamp
sudo mv /srv/kavita/library /srv/kavita/library.before-restore-$stamp
sudo cp -a $restore_dir/srv/grimoire/data /srv/grimoire/data
sudo cp -a $restore_dir/srv/grimoire/library /srv/grimoire/library
sudo cp -a $restore_dir/srv/kavita/library /srv/kavita/library
sudo install -o tunnel -g users -m 0600 \
    $restore_dir/var/backup/grimoire/grimoire.db /srv/grimoire/data/grimoire.db
sudo chown -R tunnel:users /srv/grimoire/data /srv/grimoire/library /srv/kavita/library
sudo chmod 0700 /srv/grimoire/data
sudo sqlite3 /srv/grimoire/data/grimoire.db 'PRAGMA integrity_check;'
sudo systemctl start podman-grimoire.service
curl --fail http://127.0.0.1:9481/api/health
```

The fresh data directory has no stale database WAL/SHM files. Check logs,
accounts, campaigns, portraits and books, then rescan through Grimoire to
reconcile the library and rebuild caches. Retain the private restore directory
and `.before-restore-*` directories until recovery is confirmed. Preserve
`/var/lib/kavita` independently; Grimoire recovery does not replace it.
Rolling back to Kavita uses the preserved files and credential with a reviewed
Nix configuration, followed by its own approved activation.

## Publication and activation handoff

The registry selects Link's existing nginx proxy, so the application backend
stays on loopback. It adds `rpg.finnrut.is` and the internal Grimoire alias to
Link's certificate and internal DNS inventory. The adopted Tunnel named `link`
keeps its existing connectors on Link and Impa; ingress targets Link's TLS
origin. No new public or LAN port 9481 opening is needed. The upload limit is
100 MB at nginx and remains subject to Cloudflare's request limit.

Before publication, inspect live DNS, Tunnel and Access resources for this
historical Kavita hostname and adopt any existing resources through the existing
protected import workflow. Require the provider plan to preserve unrelated
routes and bind Family Access before publishing the hostname.

The existing publication deployment wrapper builds and applies Link through
Colmena and maintains a shared inventory revision ledger. It cannot be used
unmodified for this task's required Link human approval gate. The parent must
coordinate Link's gated closure build/approval, any separately authorized Impa
DNS/configuration update, origin readiness, provider application and revision
tracking. Do not bypass the gate or revision checks. See the
[publication runbook](service-publication-runbook.md) and the
[deployment skill](/home/tunnel/.openclaw/workspace/skills/nixos-deploy/SKILL.md).

After approved activation and publication, verify the loopback health endpoint,
parent-only setup, login and role behavior, a rejected non-family client,
restart persistence, a successful offsite snapshot and an isolated restore.
Scoped fixture checks prove configuration and backup/restore mechanics; they
do not prove live HTTPS, Cloudflare policy application or deployment.

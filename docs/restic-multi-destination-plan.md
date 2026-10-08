# Restic multi-destination plan

## Status and pickup trigger

Deferred proposal, recorded 2026-10-08 at the user's request: “write all this
out to a md file in docs/ to be picked up once I clean alexandria a bit”.
**No configuration has been implemented or deployed by this plan.** Resume after
the user has cleaned alexandria and confirmed storage readiness. Findings below
are static configuration evidence, not proof of successful backups or restores.

## Intent and boundaries

- Onsite target: **alexandria**, the home Synology DS920+ at **192.168.6.9**.
  The user describes three slow SSDs; performance has not been measured. Slow
  SSDs alone do not disqualify it. Free capacity and pool redundancy are unknown.
- Preserve current OneDrive coverage and intentional exclusions. Back up
  irreplaceable data, **not whole disks or re-downloadable media**.
- Preserve dedicated `link` and `zelda` repositories. Add a shared `hosts`
  repository for other NixOS hosts that explicitly declare backup folders.
- Make the declaration available to **any NixOS host**, not only the `pc` tier.
  Service modules should contribute lists; an empty list creates no generic job.
- Do not enable the currently disabled game-server backup subsystem as part of
  this work unless separately requested.

## Current topology and source map

```text
link  home + contributed service state + dedicated RetroArch saves -> OneDrive Backups/link
zelda home + any contributed service state                       -> OneDrive Backups/zelda
link  dedicated saves subvolume -> local btrbk snapshot history (not another restic destination)
```

The desktop role imports `pc` through [modules/roles.nix](../modules/roles.nix);
[modules/laptop.nix](../modules/laptop.nix) also imports `pc`.
[modules/hosts.nix](../modules/hosts.nix) declares link as desktop and zelda as
laptop. Backup and rclone plumbing currently live in that `pc` tier.

### Shared OneDrive jobs

[modules/backup/restic.nix](../modules/backup/restic.nix) defines:

- Repository default `rclone:<remote>:Backups/<hostname>`; home and service jobs
  on a host share this repository.
- `home`: `/home/tunnel`, daily 00:00. `srv`: contributed `infra.backup.srvPaths`,
  daily 01:00, only when nonempty.
- Persistent timers with 20-minute randomized delay; backup arguments
  `--one-file-system`, `--exclude-caches`, `--retry-lock 2h`.
- Separate repository-wide prune at 03:00, retaining 14 daily, 8 weekly,
  12 monthly and 5 yearly snapshots. Default retention grouping is `host,paths`.
  Monthly check reads a 25% data subset. Backup success and maintenance success
  are intentionally separate; do not recombine prune into backup units.
- Exact current home exclude strings (preserve their semantics):

  ```text
  .local/share/Steam
  .local/share/baloo
  .local/share/Trash
  .local/share/bottles
  .local/share/lutris/runners
  .config/steamtinkerlaunch
  .config/libvirt
  .config/Ryujinx
  .config/discord
  Documents/Git
  Music/Library
  Downloads
  .var/app
  .mozilla
  .cargo
  .winebroke
  Games
  ```

Current link service contributions are `/srv/slskd`
([nicotine.nix](../modules/link/nicotine.nix)), `/srv/copyparty`
([copyparty.nix](../modules/link/copyparty.nix)), `/srv/jdownloader`
([jdownloader.nix](../modules/link/jdownloader.nix)), `/srv/actual`
([actual-budget.nix](../modules/link/actual-budget.nix)), plus RomM assets,
config and database dump directory ([romm.nix](../modules/link/romm.nix),
especially the dump preparation and `srvPaths` contribution). RomM's ROM
library is intentionally omitted. Its database dump must remain in the same
backup snapshot as the relevant application state; **a folder-only abstraction
is insufficient for consistency**. Preserve preparation hooks and safe ownership
of the dump directory when extending to two destinations.

### Special-purpose jobs and credentials

- [modules/link/saves-storage.nix](../modules/link/saves-storage.nix) backs up
  the newest completed read-only btrbk snapshot of the dedicated RetroArch saves
  subvolume, guarded for freshness. It deliberately omits `--one-file-system`,
  runs daily at 02:00, and uses tag `retroarch-saves` with grouping `host,tags`.
  Tag-specific forget runs at 04:00 with keep-last 7 plus the shared retention
  windows; shared prune reclaims space. Preserve dynamic source selection,
  freshness guard and grouping, not just a live folder path. Local btrbk history
  is not a second restic destination.
- Credentials are referenced by name only: `restic/password` and
  `restic/<hostname>rclone.age`. [modules/backup/rclone.nix](../modules/backup/rclone.nix)
  seeds mutable `/var/lib/rclone/rclone.conf` so rotating OneDrive tokens persist.
  Preserve seed ordering and avoid concurrent token-refreshing jobs sharing it.
- [modules/games/registry.nix](../modules/games/registry.nix) defaults
  `infra.games.backup.enable` to false. Test fixtures force it true; this is not
  production coverage. Conditional [games/backups.nix](../modules/games/backups.nix)
  jobs use NFS `192.168.6.9:/volume1/homes/tunnel`, mounted at `/media/alexandria`,
  with repository `/media/alexandria/Backups/games`. These are **not active and
  not mirrored current offsite backups**; keep them outside this plan.
- Prior static inventory found no other production restic NixOS jobs on impa,
  iot, marin or minish. Recheck declarations when implementation resumes.

## Proposed topology and interface

Recommended direction: **independent source-to-NAS and source-to-OneDrive jobs**,
not NAS-first replication. A slow or unavailable NAS must not gate offsite
backups. The user agreed to proceed to this document; this is a recommendation
to resume from, not finalized implementation approval.

| Source host | Onsite repository (alexandria) | Offsite repository (OneDrive) |
| --- | --- | --- |
| link | `Backups/link` | `Backups/link` (existing) |
| zelda | `Backups/zelda` | `Backups/zelda` (existing) |
| Other opted-in NixOS hosts | `Backups/hosts` | `Backups/hosts` (**assumption to confirm**) |

This proposes **six physical repositories**, not three repositories with raw
file mirrors. The third OneDrive repository was not explicitly approved by the
user. NAS paths are logical examples, not finalized mount paths or URLs.

Desired declaration shape (illustrative; option name is not finalized):

```nix
configurations.nixos.<hostname>.module.infra.backup.folders = [ paths ];
```

The user originally suggested `.module.backupFolders`. Settle the name before
implementation and decide how existing `srvPaths`, home policy and special
datasets integrate. Route link -> link, zelda -> zelda, all other opted-in hosts
-> hosts. One declaration should generate independent destination collection
and health reporting. Stagger NAS and cloud jobs, expect extra source scanning,
and do not promise identical snapshots from independent runs at different times.

## Required safeguards

- Keep offsite backups for site-loss recovery; onsite storage is not a substitute.
- Preserve explicit filesystem/subvolume coverage and exclusions. Do not blindly
  propagate `--one-file-system` into the RetroArch job or silently expand scope.
- Retain application-aware preparation. Decide how each destination consumes a
  valid RomM dump without overlapping dump writes or inconsistent state.
- Use stable hostname identity and explicit retention grouping in shared `hosts`.
  Prevent one host's retention policy from deleting another's snapshots. Grouping
  is **not authorization**: a shared repository shares an encryption/security
  boundary, including consequences of a compromised writer.
- Assign one maintenance owner per physical repository. Preserve tag-specific
  forget where needed, but avoid competing prunes. Run checks and maintenance
  independently for each destination and report their health separately.
- Plan locks, retry limits and scheduling across hosts; staggering alone is not
  a guarantee that long jobs cannot overlap.
- Monitor last successful backup freshness and failures **per destination and
  dataset**. NAS failure must not suppress cloud execution or hide cloud failure.
- NAS unavailability at boot or runtime must fail closed: never initialize or
  write a fallback repository on an unmounted local mountpoint. Define bounded
  failure/retry behavior and laptop away-from-home behavior without blocking boot.
- Prefer separate backup and maintenance privileges. Choose transport and assess
  permissions: NFS vs SFTP vs append-only rest-server remain unresolved.
- Provide password recovery independent of the lost host/site and perform
  restore tests from each destination. Never raw-file-sync a mutating restic repo.

### Alternative retained for reference

`restic copy` can transfer snapshots rather than generate independent source
events. Initialize a destination with `--copy-chunker-params` when following that
approach; copy has decrypt/re-encrypt overhead. NAS-first copy introduces a NAS
dependency for offsite freshness, so it is **not the current preference**, not a
permanently impossible option. See the official references below.

## Open questions before implementation

1. After cleanup: available capacity, pool redundancy, expected data growth,
   measured transfer/check/prune performance, and acceptable backup windows?
2. Confirm the third OneDrive `hosts` repository and cloud capacity/credentials
   for additional hosts. Which hosts and irreplaceable folders should opt in first?
3. Final NAS export/path, transport, access restrictions, repository passwords,
   recovery custody, and backup-vs-maintenance privileges?
4. Final option name and representation of home exclusions, preparation hooks,
   snapshot-backed datasets and per-dataset grouping?
5. Maintenance owner for each repo, final retention/check schedules, lock handling
   and freshness thresholds? Preserve current retention unless explicitly changed.
6. How should zelda behave away from home, and can remote hosts reach the NAS
   securely without making offsite backups depend on that route?

## Resume checklist after alexandria cleanup

- [ ] Re-read repo instructions and this plan; confirm the open decisions with the user.
- [ ] Re-inventory current jobs, contributions and exclusions; verify existing
  OneDrive snapshot freshness before changing coverage.
- [ ] Inspect NAS capacity/redundancy and measure representative performance.
- [ ] Finalize transport, repository paths, shared-repo security boundary,
  maintenance ownership and recoverable credentials.
- [ ] Implement reusable NixOS declarations outside the `pc`-only scope, with no
  generic job for an empty folder list and no accidental jobs on installer media.
- [ ] Generate independent destination jobs, preserving existing OneDrive repos,
  preparation hooks, exclusions, RetroArch guards/tags and mutable rclone state.
- [ ] Add fail-closed NAS access, bounded laptop behavior, scheduling/locking,
  independent maintenance and per-destination freshness/failure monitoring.
- [ ] Validate with the plan below, then roll out incrementally and document
  recovery commands and evidence. Do not enable game-server backups implicitly.

## Future validation plan (not run for this document)

- Targeted evaluation per affected host: link, zelda, an opted-in non-`pc` host,
  an empty-list host, and installer-media exclusion. Inspect generated jobs,
  routing, timers, exclusions, filesystem coverage, hooks, credentials references,
  grouping and the single maintenance owner for each physical repo.
- Demonstrate NAS unavailable/unmounted behavior without local fallback writes;
  verify cloud jobs still run. Exercise laptop absence, lock contention and
  preparation failure. Verify success markers only advance after successful work.
- Collect runtime backup/snapshot evidence independently from each destination;
  inspect actual paths and exclusions, RomM dump coverage, RetroArch snapshot
  freshness, retention grouping and per-destination monitoring. Configuration
  evaluation alone is not recovery evidence.
- Run repository integrity checks and representative restores from **both**
  destinations, including RomM database plus assets and RetroArch saves. Test
  password recovery and record dates/results; a partial data check is not a full
  restore test. Consult official check guidance below.
- Leave full checks to CI by default. Any approved long-running local Nix
  validation is delegated to a background fixer using the `agent-run-long`
  skill/helper; report unavailable delegation rather than silently running it.
  New source files must be staged before future Git-backed flake evaluation, but
  **nothing is staged, built or evaluated as part of writing this plan**.

## Official references

These supplied official references are for implementation pickup; no external
research or live infrastructure validation was performed for this document.

- [Copying snapshots between repositories](https://restic.readthedocs.io/en/stable/045_working_with_repos.html#copying-snapshots-between-repositories)
- [Checking integrity and consistency](https://restic.readthedocs.io/en/stable/045_working_with_repos.html#checking-integrity-and-consistency)
- [Security considerations in append-only mode](https://restic.readthedocs.io/en/stable/060_forget.html#security-considerations-in-append-only-mode)
- [Scheduling backups](https://restic.readthedocs.io/en/stable/040_backup.html#scheduling-backups)
- [rest-server](https://github.com/restic/rest-server)

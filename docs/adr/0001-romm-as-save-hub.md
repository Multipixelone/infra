---
Status: superseded by ADR-0002
---

# RomM is the save hub; Syncthing is retired for saves and ROMs

Save files used to live in a Syncthing folder fanned out to eight devices, sent
one-way from `link` — so `link`'s copy was the only history that mattered and
every other device's writes were silently dropped. RomM's in-browser player
writes saves straight into its own asset store on every in-game save, so once
RomM exists it is unavoidably a participant; running it alongside Syncthing
would mean two sources of truth for the same bytes. We made RomM the single
hub: the web client and Grout on the muOS RG35XXSP both sync through its API,
Syncthing's `roms` and `saves` folders are unshared, and conflicts surface in
RomM's UI as two save entries instead of vanishing into `.stversions/`.

## Consequences

**Desktop RetroArch is not synced.** RomM ships no first-party desktop client;
the only options were a third-party GTK tray app or a daemon of our own, and
both were deferred. Saving in RetroArch on `link` or `zelda` produces a save
nothing else sees. This is the deliberate cost of shipping the hub early, not
an oversight.

**Save states are machine-local, permanently.** Grout syncs save files only,
and states are core- and build-specific — a `snes9x` state does not load in
whatever core muOS ships. Retiring Syncthing removed the only thing that had
ever moved them, and they were never actually synced before, so nothing was
lost.

**A fixed allowlist of paths is bypassed at the Cloudflare edge, not all of
`/api/`.** Grout authenticates with a RomM Client API Token and cannot complete
an Access identity challenge, so the paths it calls must be reachable without
one. Bypassing the whole `/api/` prefix would have been wrong: RomM's
`@protected_route` builds its guard as `_requires_scopes(scopes or [])`, and an
empty scope list makes starlette's `has_required_scope` return true, so
`@protected_route(m, p, [])` is as open as no decorator. Fifteen `/api/` routes
are anonymous that way, four guarded only by "no admin user exists yet" —
including `POST /api/users` with the role settable from the body. On a first
deploy the database has no admins while DNS, tunnel and bypass come up
together, so a blanket bypass would leave a window for any internet caller to
create itself an administrator. The allowlist is enumerated from Grout's own
endpoint table and excludes `/api/users`, `/api/setup/*`, `/api/feeds/*`,
`/api/docs` and `/api/redoc`.

The allowlist also has to include `/assets/romm/resources/`, which is **not**
under `/api/` — it is an nginx static alias, and every piece of cover art,
fanart and screenshot Grout renders comes from it.

`DISABLE_DOWNLOAD_ENDPOINT_AUTH` must stay off: with any of these paths
edge-bypassed it would make the library world-downloadable.

**The Postgres dump is written outside `dataDir`.** It runs from
`restic-backups-srv`, which is root and carries no `ProtectSystem`, while every
directory under `dataDir` is writable by the `romm` service user. Root creating
or chowning a path that service can replace with a symlink would hand it an
arbitrary root-owned `chown` — the exact escalation the romm units'
`NoNewPrivileges`/`ProtectSystem=strict` sandbox exists to prevent. The dump
lives in a root-owned `/var/backup/romm` created declaratively by tmpfiles, and
`pg_dump` writes to a descriptor root already opened.

**RomM owns the ROM files.** The library is read-write rather than the
read-only igir mount upstream suggests, so ROMs can be added through the web UI
without a re-import. igir is the bulk-import tool, not a permanent gatekeeper.

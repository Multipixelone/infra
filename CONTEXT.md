# infra

Vocabulary specific to this repository. General Nix, NixOS and systemd terms do
not belong here; conventions for those live in [`AGENTS.md`](./AGENTS.md).

## Game library and saves

**Library**:
The tree of ROM files RomM owns, at `/media/Data/romm/library`, laid out as
`roms/<platform-slug>/` and `bios/<platform-slug>/`. Re-acquirable, so it is
deliberately excluded from backups.
_Avoid_: collection, ROM folder

**Assets**:
RomM's per-user, per-ROM store of save files, save states and screenshots. The
irreplaceable half of RomM's state, and meaningless without the Postgres rows
that describe it — the two are backed up together.
_Avoid_: saves folder, user data

**Save file**:
The in-game save the emulated game itself writes (`.srm`, `.sav`, `.mcr`, …).
It is the only recovery-critical game progress shared between sync clients;
compatibility across different cores is not assumed.
_Avoid_: save, savegame, SRAM

**Save state**:
A snapshot of the whole emulator at one moment. It is core- and build-specific
and may be carried by Cloud Sync because save files and save states cannot be
selected separately. It is optional rather than recovery-critical or portable;
durable progress must use save files.
_Avoid_: save, snapshot

**ROM authority**:
The canonical ROM collection owned by RomM. Distributed copies may be
one-way replicas, but changes to them never flow back into the Library.
_Avoid_: hub, master, ROM folder

**Content identity**:
The stable Library-relative path and filename stem assigned after RomM imports,
tags and renames a ROM. Save files, playlists and per-game Core-policy exceptions
refer to that identity; changing it requires an explicit migration.
_Avoid_: ROM ID, game name, current filename

**Save authority**:
The sole canonical save-file history from which every sync client reads and to
which it writes. It is deliberately separate from the ROM authority.
_Avoid_: hub, master, saves folder

**Sync client**:
A RetroArch installation, or another implementation proven compatible with
its cloud-sync protocol, that participates in the save authority. Generic
WebDAV access alone does not qualify.
_Avoid_: device, machine, host

**Client profile**:
The centrally declared projection of the Library assigned to one sync client:
complete emulated systems plus explicit per-game inclusions and exclusions,
together with that client's local paths and Core-policy associations.
Contradictory selections are invalid.
_Avoid_: device config, ROM subset, ignore list

**Core policy**:
The canonical mapping from each emulated system to its default RetroArch core,
plus explicit per-game exceptions. Sync clients derive local core associations
from it; a client that lacks the prescribed core must offer to install it or
fail rather than silently substitute another core.
_Avoid_: emulator choice, core preference, default emulator

**Seed**:
The one-time introduction of one verified save file per game into an empty save
authority. Distinct from sync, which is continuous and bidirectional.
_Avoid_: migration, initial sync

**Origin**:
The local nginx virtual host RomM serves itself on, which the publication proxy
points at. Not the published hostname — RomM's backend speaks only API, while
nginx serves the frontend, ROM downloads and the emulator's cross-origin
isolation headers.
_Avoid_: backend, upstream

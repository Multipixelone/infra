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
Interchangeable across cores of the same platform, and the only thing that
syncs between devices.
_Avoid_: save, savegame, SRAM

**Save state**:
A snapshot of the whole emulator at one moment. Core- and build-specific, never
synced, and local to the machine that wrote it.
_Avoid_: save, snapshot

**Hub**:
RomM, as the single source of truth every client reads from and writes back to.
Clients hold copies; the hub holds the history.
_Avoid_: server, master

**Device**:
An endpoint registered with RomM and bound to a Client API Token, so the sync
orchestrator can attribute a save to whatever wrote it. The RG35XXSP is one;
`link` and `zelda` are not, because desktop RetroArch does not sync.
_Avoid_: client, machine, host

**Seed**:
The one-time import of pre-existing save files into an empty RomM, over the
API, after the ROM library has been imported and renamed. Distinct from sync,
which is continuous and bidirectional.
_Avoid_: migration, initial sync

**Origin**:
The local nginx virtual host RomM serves itself on, which the publication proxy
points at. Not the published hostname — RomM's backend speaks only API, while
nginx serves the frontend, ROM downloads and the emulator's cross-origin
isolation headers.
_Avoid_: backend, upstream

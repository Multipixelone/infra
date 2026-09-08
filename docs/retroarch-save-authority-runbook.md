# RetroArch save authority runbook

The save authority is a WebDAV endpoint at `saves.finnrut.is`, served by rclone
from a dedicated Btrfs subvolume on `link`, and reached by every sync client
through RetroArch's own Cloud Sync. The decision and its accepted costs are in
[`adr/0002-retroarch-cloud-sync-as-save-authority.md`](adr/0002-retroarch-cloud-sync-as-save-authority.md);
this document is how it is operated. The Core policy and the three Client
profiles are data in `modules/gaming/saves/policy.nix`, resolved into
`config.flake.saveSyncInventory`, and every projection named below comes from
there rather than from a hand-maintained list.

Read the ADR first, and in particular the unmet requirement: RetroArch does not
sync on reconnect. It syncs at startup, at core _unload_, when someone picks
"Sync Now", and — on iOS — on foreground-resume after more than sixty seconds
backgrounded. There is no retry, no backoff and no durable queue, and a failed
sync's only visible trace is the word "failures" appended to a task title.
Almost everything procedural in this runbook exists because the software does
not do that for you.

Where a step below needs a tool from this repository, the step says what the
tool does. Confirm the exact command against `just --list` and
`nix flake show` before running it; do not assume a name from this document.

## Never switch a save-authority host generically

The rclone WebDAV unit, the managed `retroarch.cfg`, the Syncthing folder and
device declarations and the btrbk instance all live in ordinary host modules on
`link`. **Any** switch of that host ships all of them at once: `just rebuild`,
`nh os switch`, `genswitch`, `just colmena-apply` and every tagged variant.
None of them checks that the subvolume exists, that the credential file is
populated, that the remote namespace holds what you think it holds, or that any
client has been quiesced. Three of those consequences are destructive rather
than merely surprising:

`services.syncthing.overrideFolders` and `services.syncthing.overrideDevices`
both default to `true`, and on activation they delete undeclared folders and
devices over Syncthing's REST API. `link` declares no folders and no devices
today but carries live runtime state, including a retired saves folder. The
first activation that touches the Syncthing module removes that state without
prompting. Read the live configuration off the host and reconcile it into Nix
before deploying, or accept the deletion deliberately.

`config_save_on_exit = false` takes the live 3333-line `retroarch.cfg` out of
RetroArch's hands permanently. If `saveSync.retroarch.manageConfig` is on while
`saveSync.retroarch.baseSettings` is empty, evaluation refuses — but it cannot
refuse a `baseSettings` imported from the wrong machine or from a stale
snapshot. That refusal is a floor, not a review. See **Importing and diffing
the RetroArch configuration**.

`restic`'s shared options include `--one-file-system`, and a new Btrfs
subvolume gets its own `st_dev`, so a backup that is supposed to cover
`/media/Data/retroarch-saves` will walk straight past it and exit `0`. If the
save authority is expected to be in `restic-backups-srv`, prove it by listing
files under that path in a restored snapshot. An exit code proves nothing here.

So: quiesce every client before a switch that touches any of this, deploy,
verify, and only then let clients sync again. Deploy unrelated host work
separately and before the save-authority change, or after it.

## What the operator must create by hand

None of the following can be created from this repository, and each of them is
a precondition rather than a nice-to-have.

**The Btrfs subvolume.** Nothing creates `/media/Data/retroarch-saves`. Run
`sudo btrfs subvolume create /media/Data/retroarch-saves` on `link` before the
first deploy. A plain directory would satisfy rclone and would silently make
btrbk's snapshots impossible, which is the failure you would discover during a
recovery. `/media/Data` is `subvol=/@music` on the `4Tera` device and the same
subvolume is also mounted at `/volume1/Media`; nothing on that device is
mounted at `subvolid=5`, so the new subvolume must be created through one of
those two mount points. There is 1.1 TiB free.

**The BIOS directory.** `/media/Data/romm/library/bios` does not exist yet,
although every BIOS-channel projection names it. The Library is `0750
romm:romm` and `tunnel` is declaratively a member of the `romm` group, so
`sg romm -c 'ls /media/Data/romm/library'` reads it without sudo — but creating
a directory inside a RomM-owned tree, with RomM's ownership, is an operator
action.

**Every Syncthing device ID.** A device ID is derived from that device's own
key material on first run. Read each one off the device itself and paste it in.
Never invent one, and never copy one from another device's configuration.

**Every WebDAV password and the htpasswd file.** See **Credentials** below.
The repository holds no cleartext and no hash; both are generated by the
operator.

**The Cloudflare rate limit and WAF rules.** See **Cloudflare WAF and rate
limiting** below.

## Provisioning a sync client

A sync client is a RetroArch installation that participates in the save
authority. Generic WebDAV access is not enough — the client has to implement
the same sync protocol and the same conflict behaviour.

**Managed clients** (`managed = true`; today only `link`). Add the client to
`saveSync.clients` in `modules/gaming/saves/policy.nix` with its platform, its
complete `systems` list, and all eight paths — `roms`, `bios`, `saves`,
`states`, `playlists`, `config`, `system` and `coreAssets`. `coreAssets` is
named explicitly because Cloud Sync keeps its state there; getting it wrong
makes recovery fail in a way that looks like data loss. Evaluate before
deploying: the resolved inventory asserts on its `errors` list, so a
contradictory profile fails the build rather than degrading to a subset, and
`requiredCores` grows to cover the new client so the `withCores` list cannot
drift from the policy. Mint that installation's credential, quiesce the other
clients, deploy, then read the deployed `retroarch.cfg` back and confirm the
managed keys are what the policy says — in particular that `webdav_url` is the
full `https://saves.finnrut.is/` with the scheme written out, because a URL
with no scheme defaults to `http://`. Finally trigger one sync and confirm
`manifest.local` and `manifest.server` appeared under the client's `coreAssets`
directory.

**Unmanaged clients** (`managed = false`; today the iOS and Android handhelds).
They get the same policy entry, usually with an empty `systems` list and
explicit `includeGames`, and they get generated artifacts plus a validation
report — but a human applies them, and nothing detects it if a human does not.
Write the generated ignore patterns from `stignore.<client>.roms` and
`stignore.<client>.bios` onto the device; remember that `.stignore` comments
start with `//`, never `#`, that the first matching pattern wins top-down, and
that a rooted negation such as `!/gba` does not force Syncthing to descend into
an ignored directory the way an unrooted one does. Install the prescribed cores
by hand — a client missing its prescribed core must offer to install it or
fail, never silently substitute another core, because battery-save
compatibility across cores is not assumed. Then enter the sync settings by hand
and _read them back_: `cloud_sync_enable` true, `cloud_sync_driver` `webdav`,
`cloud_sync_destructive` false, `cloud_sync_sync_saves` true,
`cloud_sync_sync_configs`, `cloud_sync_sync_thumbs` and `cloud_sync_sync_system`
false, `sort_savefiles_enable` and `sort_savestates_enable` false,
`sort_savefiles_by_content_enable` and `sort_savestates_by_content_enable`
true. The two sort settings are not interchangeable: RetroArch applies
by-content first and core name second, so leaving core-name sorting on
reintroduces the core's _display_ name into the remote path, and display names
change between core builds — two clients on different mGBA revisions would then
write one game's saves into two unrelated directories, and Cloud Sync would
treat them as two files rather than as a conflict.

Record which physical installation holds which credential as you go. That
mapping is the only thing that makes revocation surgical.

## Credentials: staging, rotation, revocation

One credential per **physical installation** — not per person, not per client
profile, not per device model. Reinstalling RetroArch on the same handheld is a
new installation and gets a new credential. The whole point is that losing one
device revokes one credential and nothing else.

The server holds only bcrypt hashes. Generate them with `htpasswd -B` (from
`pkgs.apacheHttpd`): `htpasswd -B -c <file> <user>` for the first entry,
`htpasswd -B <file> <user>` for each one after — `-c` truncates, so using it
twice deletes every credential you already staged. rclone 1.75's `--htpasswd`
supports bcrypt and its own documentation recommends it over the alternatives.

The htpasswd file is delivered by agenix and handed to the unit through
`LoadCredential=`, so it is materialised at `$CREDENTIALS_DIRECTORY/<id>` with
mode `0400` on ramfs and never enters the Nix store. Stage it the usual way:

```bash
cd /home/tunnel/Documents/Git/nix-secrets
agenix -e <the path the WebDAV module's age.secrets declaration names>.age \
  -i /home/tunnel/.ssh/agenix
```

The password manager is the recovery source for the cleartext, and the only
one. The server cannot produce it — it holds a bcrypt hash — and neither can
this repository. A password that is not in the password manager does not
exist; when the device that held it dies, the credential is simply gone and
must be rotated. Never paste a password into `retroarch.cfg` under Nix's
ownership: `webdav_username` and `webdav_password` are both on the exact
`secretKeys` list in `lib/retroarch-saves.nix` and are deliberately absent from
the managed settings, so they are injected at runtime into a mode-`0600` file
outside the store.

**Rotation is two deployments, never one.** Mint the new password, add its hash
alongside the old one, deploy, reconfigure that single device, confirm it
completes a sync, and only then remove the old hash and deploy again. Doing it
in one step locks the device out at the moment you need it working to prove the
new credential.

**Revocation is one deployment plus a proof.** Remove the line, deploy, then
make an actual request with the revoked credential and confirm a `401`, and one
with a surviving credential and confirm it still works. Do not infer from a
successful activation that the running process re-read the file.

Rotate on reinstall, on retirement or disposal of a device, on loss or theft,
and on any suspicion the cleartext was captured — including a password typed
into a handheld in front of someone. Rotation is cheap here by construction;
treat it as routine rather than as an incident.

## Importing and diffing the RetroArch configuration

The live `retroarch.cfg` on `link` is 3333 lines and every line matches
`^[a-z0-9_]+ = "..."$`. Nix does not get to own it until a human has read the
difference between what is there now and what would be rendered.

1. **Snapshot.** Copy the live `~/.config/retroarch/retroarch.cfg` to a working
   directory that is outside this Git repository and outside the Nix store.
   Keep it: it is the only record of what the file said beforehand.
2. **Scan for secrets.** Use the exact `secretKeys` list in
   `lib/retroarch-saves.nix` plus an entropy check on the values. Do **not**
   use a `password|token|key` substring regex. On this file that regex
   false-positives on eleven entirely benign settings —
   `input_enable_hotkey`, `input_enable_hotkey_axis`, `input_enable_hotkey_btn`,
   `input_enable_hotkey_mbtn`, `input_hotkey_block_delay`,
   `input_keyboard_layout`, `input_nowinkey_enable`, `keyboard_gamepad_enable`,
   `keyboard_gamepad_mapping_type`, `netplay_show_passworded` and
   `vibrate_on_keypress` — while the key that actually matters, `cheevos_token`,
   is populated with sixteen characters of real RetroAchievements credential. A
   scan that cries wolf eleven times is a scan whose twelfth result gets waved
   through.
3. **Normalise into Nix.** `retroarch-config-import` emits the secret-free
   settings for `saveSync.retroarch.baseSettings` and refuses to emit any key
   on `secretKeys`. Confirm its exact invocation against `nix flake show` and
   `just --list`.
4. **Render.** With `baseSettings` populated, the rendered configuration is
   those settings with the managed keys layered over them; managed keys always
   win.
5. **Diff generated against live**, and read every line of the difference.
   Expect and accept: `config_save_on_exit`, the whole `cloud_sync_*` block,
   the four sort keys, and the save and state paths. Expect and _investigate_
   anything pointing into `/nix/store` — the live file still points
   `libretro_directory` at a RetroArch 1.20.0 store path while the running
   binary is 1.22.2, which is drift the diff should be removing rather than
   faithfully preserving, and that store path is garbage-collectable.
6. **Operator reviews and signs off.** Evaluation already refuses
   `manageConfig` with an empty `baseSettings`; that is a floor and not a
   substitute for reading the diff.
7. **Only then does Nix become authoritative**: set
   `saveSync.retroarch.manageConfig = true` and deploy. From that point every
   persistent settings change is a Nix edit, because RetroArch will no longer
   write the file back.

The snapshot and the diff live outside Git and outside the Nix store for the
whole of this workflow. The snapshot contains `cheevos_token`, and everything
in the Nix store is world-readable.

## Recovery

Run these steps in this order. The order is the procedure; a step taken early
undoes the ones before it.

1. **Restore snapshot data into a quarantine namespace.** btrbk's snapshots
   under `/media/Data/.retroarch-save-snapshots` are always read-only, and
   there is no configuration key to change that — do not try to flip `ro` on
   one. Make a writable copy with
   `sudo btrfs subvolume snapshot <read-only-snapshot> <quarantine-path>`,
   deliberately **without** `-r`, and serve or mount that as a separate WebDAV
   namespace. Never restore over `/media/Data/retroarch-saves`.
2. **Freeze every other client.** Cloud sync off, or the device offline. One
   client syncing during a recovery re-uploads the state you are replacing, and
   because RetroArch's non-destructive path touches neither copy of a
   conflicting file, the result is a stalled namespace rather than a restored
   one.
3. **Connect exactly one isolated client** to the quarantine namespace.
4. **Discard or rename that client's stale local manifest first.** RetroArch
   keeps its sync state in `core_assets_directory`, which is the _downloads_
   directory — `~/.config/retroarch/downloads` on `link`, and each unmanaged
   client's own `coreAssets` path elsewhere. The two files are
   `~/.config/retroarch/downloads/manifest.local` and
   `~/.config/retroarch/downloads/manifest.server`. Nothing about the name
   "downloads" suggests sync state lives there, which is exactly why this step
   gets skipped. A manifest that still describes the live namespace makes every
   restored file look either like a server-side change or like a conflict,
   depending on what the local copy happens to say.
   While you are in that directory, look at `<core_assets>/cloud_backups/`.
   When a server fetch would have overwritten a local file, the non-destructive
   path _renames_ the local copy to
   `<core_assets>/cloud_backups/<portable/path>-YYMMDD-HHMMSS` rather than
   discarding it. That directory is where a save went if one appears to have
   vanished; check it before concluding anything is lost.
5. **Synchronise, then verify by hash.** Compare `sha256sum` of the files on
   the client against the files in the quarantine namespace. "The task said it
   finished" is not verification, and a sync that failed says so only by adding
   the word "failures" to a task title.
6. **Deliberately reseed the live namespace** from the verified quarantine
   content. This is an explicit act — empty the live namespace, place the
   verified set into it — and not a sync between the two namespaces. Letting
   them sync makes the outcome depend on manifests you have just invalidated.
7. **Reconnect the other clients only after that verification**, one at a time,
   each with its stale manifest discarded first, each verified before the next
   one is unfrozen.

## Pilot checklist

The pilot is RomM ROM ID 110, `gba/Pokemon - Emerald-R 260525`, on `link`
plus one handheld. Its exact RomM filename is `Pokemon - Emerald-R 260525.gba`;
the content identity intentionally preserves that filename stem for save
matching even though upstream calls it **Pokémon Revelation v260525**. Confirmed
ROM identification: 33,554,432 bytes; CRC32 `37db95de`; MD5/RetroAchievements
`9587aa325471ea1e3cb68958db5072fc`; SHA-1
`1bcfb800b38cb9080446570ea75b44b9982dfe98`. Nothing beyond the pilot game gets
seeded until all seven pass.

**Legacy v231014 warning.** `Pokemon Emerald-R v231014` saves are not save-file
matches for this pilot. Retain the old ROM and every old save; copy a legacy save
only for an explicit copy-and-verify compatibility test under the prescribed
mGBA core, and keep both originals until that test has passed.

1. **Initial seed and second-client pull, with matching hashes.** Seed one
   verified save for the pilot title into an empty namespace from `link`, sync,
   pull it to the second client, and compare `sha256sum` on both ends. Matching
   hashes — not "the file appeared".
2. **Both clients on mGBA, one save namespace.** Confirm the prescribed core
   for `gba` is `mgba` on both clients and that the save lands in exactly one
   remote directory, named for the Library platform directory `gba`, not two
   directories named after core display names. That is exactly what
   `sort_savefiles_by_content_enable` being on, with `sort_savefiles_enable`
   off, is for.
3. **Offline progress survives and uploads after a later explicit sync.** Play
   offline on the second client, confirm the save is on local disk, reconnect
   the network, and observe that _nothing happens by itself_. Then trigger a
   sync — unload the core, or use "Sync Now" — and verify the new bytes
   arrived. The step where nothing happens is the point of the test: it is the
   unmet requirement being demonstrated, not a fault to debug.
4. **Deliberate divergence preserves both versions.** Change the same save on
   both clients without syncing in between, then sync both. Expect neither file
   to be modified and `Conflicting change of` in the log, and confirm by hash
   that both distinct versions still exist. If either side was overwritten,
   `cloud_sync_destructive` is not `false` on that client and the design is
   void until it is.
5. **Snapshot recovery restores to quarantine and can be deliberately
   promoted.** Run the whole **Recovery** sequence on the pilot save: a real
   btrbk snapshot, a real writable copy, a real quarantine namespace, a real
   promotion to the live namespace. Reading the section is not the test.
6. **Revoking one credential leaves the other working.** Remove one
   installation's hash, deploy, confirm that client now gets `401` and cannot
   sync, and confirm the other client completes a sync in the same minute.
7. **ROMs, BIOS, saves and optional states stay in their intended channels.**
   Confirm no ROM reached the save namespace, no save reached the ROM replica
   (the ROM channel is one-way and never pushes back at the Library), BIOS
   arrived only over the one-way BIOS dataset, and any save states are under
   the `states` prefix and nowhere else. The BIOS setting is
   `cloud_sync_sync_system = false`; there is no `cloud_sync_sync_systemfiles`
   key in any RetroArch release, so a config that names one is silently doing
   nothing.

## RetroArch upgrades are compatibility events

Treat every RetroArch update on every client as a compatibility event, and
rerun the Cloud Sync smoke test after it: read the sync settings back and
confirm they are still what the policy says, round-trip one small save between
two clients and compare hashes, and reproduce one deliberate conflict and
confirm it still stalls instead of resolving.

The settings surface is not stable API and has already moved inside the range
we support — `cloud_sync_sync_mode` is new in 1.22.2 and is simply ignored by
older builds. On `link` the configuration is rendered from Nix, so the risk is
a renamed key quietly becoming inert; on the unmanaged clients an App Store or
APK update can reset settings outright, and nothing will tell you. An update
that changes the manifest format is possible, and it would present as a full
re-upload or a wave of conflicts on first launch. If that happens: stop, do not
resolve conflicts in bulk, and treat it as a recovery.

## Cloudflare WAF and rate limiting

`saves.finnrut.is` is a public WebDAV endpoint whose only authentication is
HTTP Basic. rclone's server implements `OPTIONS GET HEAD POST PUT DELETE MKCOL
COPY MOVE PROPFIND PROPPATCH LOCK UNLOCK` — `DELETE` and `MOVE` are in that
list — and a password is the only thing in front of them. It cannot sit behind
Cloudflare Access, because RetroArch cannot complete an identity challenge;
this is the same constraint Grout has, for the same reason.

**This repository cannot configure the mitigation.** Rate limiting and WAF
rules for this hostname are an operator action, in the Cloudflare
configuration owned by the service publication work, and the endpoint should
not be exposed to the internet before they exist. At a minimum: a per-source
request rate limit low enough to make Basic-auth brute force impractical, and
visibility on sustained `401` responses.

Note the monitoring gap honestly. There is no nginx exporter and no Loki ruler,
so 4xx and authentication-failure alerting is not possible from the local
stack today; the node-exporter textfile collector on `link` is the only hook
available, and Cloudflare's own analytics is the only view of what the edge is
absorbing. Do not write an alert rule that pretends otherwise.

Two behaviours worth knowing before reading a scanner report: rclone issues no
redirects at all, so `GET /dir` without a trailing slash is a hard `405` while
`GET /dir/` returns an HTML listing unless directory listing is disabled.
Neither is a security control; both change what an automated probe reports.

## The Core policy extraction boundary

The Core policy and the Client profiles stay in this repository. Nothing in
`modules/gaming/saves/policy.nix` is a credential, a Library inventory or a
content hash: the system keys are public platform directory names, the cores
are public libretro attribute names, and exactly one game is named — the pilot
— because exactly one profile references it. Forty-two GBA ROMs exist and one
appears. That material is no more sensitive than the rest of this tree, and a
separate repository would buy nothing.

It earns a dedicated private Forgejo repository when at least one of these
becomes true, and not before:

- `contentIdentities` grows past the handful the profiles genuinely reference
  and becomes a de facto Library inventory — that is, the policy starts naming
  games a reader of this repository should not learn about;
- the policy acquires a release cadence of its own, changing more often than
  the system configuration and needing to ship without a NixOS rebuild;
- a second consumer appears that needs the policy without needing this flake,
  such as a device that reads the projections directly rather than receiving
  generated artifacts from a deploy.

Until then, extraction costs a second flake input, a second CI surface, and a
policy that can drift from the module that validates it. Do not create that
repository speculatively.

## Migrating the existing saves

**Freeze writes first.** Every client stops emulating anything before the
archive is taken. A save written halfway through the archive is a save with no
verified copy of itself.

**Archive and hash everything, including the junk.**
`/home/tunnel/.config/retroarch/saves` on `link` holds 131 save files, sorted
by core _display_ name as `saves/<CoreDisplayName>/<stem>.<ext>`, with
extensions `srm` (125), `sav` (2), `dsv` (2) and `rtc` (1); the `states/`
directories exist but are empty. The tree is not clean. There are roughly
seventy files under `.stversions/` left behind by the retired Syncthing
versioning, eight `*.sync-conflict-YYYYMMDD-HHMMSS-XXXXXXX.*` files, a
`.stfolder` marker, and one stray save sitting at the `saves/` root. Archive
all of it with a hash for every file. The junk is precisely where the
alternative version of a save you are about to choose wrongly will be found —
`.stversions` and the sync-conflict files are the recorded output of the
failure mode ADR-0001 retired. Read one tree and write another; never move or
delete an original.

**Choose one verified save per game.** Verified means opened under the core the
policy prescribes and confirmed to load with the progress it should have. This
is not a formality: legacy `Pokemon Emerald-R v231014.srm` files exist under
**both** `gpSP` and `mGBA` in the live tree, while the policy now names the
different v260525 RomM stem. Preserve the legacy ROM and saves; do not copy one
into the v260525 identity except for an explicit copy-and-verify compatibility
test under mGBA. The cores disagree about GBA flash-save sizing often enough
that portability has to be demonstrated rather than assumed. `gpsp` and `bsnes`
stay installed as `extraCores` for exactly this reason — they wrote saves that
are still on disk, and a save has to be openable before it can be verified and
exported.

**Start with an empty remote authority.** Do not create the namespace by
uploading the existing tree. The existing tree is core-name sorted; the new
layout is content-directory sorted. A bulk upload writes 131 files into paths
the policy does not use, and every one of them then has to be found and removed
from a namespace that other clients are already pulling. Seed from one client —
`link` — one verified save per game, into an empty namespace.

**Prove second-client retrieval before broader rollout.** The pilot checklist
above is that proof for one game. Extend only after all seven of its criteria
pass.

**Never bulk-upload every historical save.** There is no undo. An upload that
creates a file no other client has ever seen is not a conflict — it is just a
file, and it will be pulled everywhere.

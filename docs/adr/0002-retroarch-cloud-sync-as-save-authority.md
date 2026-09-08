---
Status: accepted
---

# RetroArch Cloud Sync over WebDAV is the save authority; RomM stays the ROM authority

[ADR-0001](0001-romm-as-save-hub.md) made RomM the save hub and wrote down its
own cost in the first line of its consequences: desktop RetroArch is not
synced. That cost never got cheaper. RomM still ships no first-party desktop
client — the choices were a third-party GTK tray app or a daemon of our own,
and both are still deferred — so Grout covers the handheld, the in-browser
player covers the browser, and saving in RetroArch on `link` still produces a
save nothing else sees. RetroArch's own Cloud Sync is the only first-party
mechanism that covers desktop, iOS and Android at once, and the driver it
covers them with is WebDAV. So the save authority moves out of RomM's Assets
store: it is now a WebDAV endpoint published at `saves.finnrut.is`, served by
rclone from a dedicated Btrfs subvolume on `link`, and every sync client reads
and writes it through RetroArch itself rather than through an API only some of
them can speak.

RomM keeps the ROM authority, and the separation is deliberate rather than
transitional. RomM is what imports, tags and renames a ROM, which is what fixes
its content identity; the save authority stores files named after that identity
and knows nothing about where it came from. Because the two are separate, the
ROM channel can stay one-way — replicas that never push back at the Library —
while the save channel is bidirectional and conflict-bearing, which is the only
shape that is true of both. Merging them again would mean either making the
Library writable from every handheld or making saves read-only somewhere, and
neither is acceptable.

One requirement is explicitly not met: RetroArch has no automatic-on-reconnect
behaviour. Read from the source, the complete list of things that start a sync
is startup, core _unload_ (not load), the menu's "Sync Now", and — on iOS only
— foreground-resume after more than sixty seconds backgrounded. There is no
network-up hook, no retry, no backoff and no durable queue. A sync that fails
because the endpoint was unreachable is not re-attempted when it becomes
reachable again; the failure sets a flag whose only user-visible effect is that
the task title gains the word "failures". Offline play works exactly as it
always did, because RetroArch writes the save locally either way, but the save
does not leave the machine until someone triggers a sync _and_ confirms it
succeeded, and it must be confirmed before that game is opened on another
client. This deployment is therefore the best available interim solution, not a
complete one, and the runbook is written to compensate procedurally for what
the software does not do.

The sync category is coarser than the vocabulary is. `cloud_sync_sync_saves` is
a single boolean and `task_cloud_sync_directory_map` expands it onto two remote
prefixes, `saves` and `states`; there is no supported battery-save-only toggle
anywhere in the release. Save states will therefore cross machines whether or
not that is wanted. They remain what they were: core- and build-specific,
optional, not portable, and not recovery-critical. Durable progress must live
in the save files the emulated game itself writes, and a save state must never
be the only copy of anything that matters.

Conflicts preserve both versions, and they do it by RetroArch declining to act.
With `cloud_sync_destructive = false`, when the local file and the server file
have both changed since the recorded manifest, RetroArch touches _neither_
copy and logs `Conflicting change of %s.` Nothing is renamed, nothing is
merged, and there are no conflicted-copy filenames to go looking for: both
versions simply stay where they are until a person decides. Newest-wins and
preferred-client-wins are implemented nowhere in this design and must never be.
The three clients' clocks are a desktop, a sandboxed iOS app and an Android
handheld, a save file's mtime is set by whichever of them wrote last rather
than by which session was longer, and an automatic rule built on that silently
destroys the loser. A stalled conflict is loud and recoverable; a resolved one
is neither.

## Consequences

**`config_save_on_exit` must become `false`, so every persistent UI change is
henceforth a Nix edit.** RetroArch rewrites the whole of `retroarch.cfg` on
exit, so Nix cannot own a file it also overwrites; the sync settings would be
silently reverted by the next clean shutdown. The evidence that this is a real
failure mode and not a theoretical one is already in the live config: it still
points `libretro_directory` at a RetroArch 1.20.0 store path while the running
binary is 1.22.2. That is this exact setting's drift, made visible — a value
written months ago by a program that thought it owned the file, still there
after the package moved. It is also a live hazard, because that store path is
garbage-collectable and nothing holds a GC root on it. The price is that
changing a setting in the menu no longer sticks: it goes in `saveSync` and gets
deployed.

**Save states now cross machines even though they are useless there.** The
category cannot be split, so accepting Cloud Sync for save files means
accepting it for states. A `snes9x` state from `link` will land on the iOS
client, where it will not load, and it will consume space and sync time on the
way. This is a known, accepted waste rather than an oversight; the alternative
was to give up first-party sync entirely.

**The btrbk module grants the `btrbk` user passwordless root over btrfs.** To
let its unit snapshot a subvolume it does not own, the NixOS module installs a
NOPASSWD sudo rule for user `btrbk` covering `btrfs`, `mkdir` and `readlink` —
and `btrfs` there is the whole command, including `subvolume delete` against
any path on the system. That is a new passwordless-root surface on `link`,
created for the sake of local save snapshots. It is the price of using the
module instead of hand-writing the timer, and it is written down here so that
nobody later finds the sudoers entry and assumes it was an accident.

**The backend hop is plaintext HTTP across the LAN, carrying HTTP Basic
credentials.** The site's default proxy is `impa`, so a route whose backend is
`link` means nginx terminates TLS on `192.168.6.50` and proxies over the LAN to
`192.168.6.6` in the clear, with each client's WebDAV username and password in
an `Authorization` header on every request. This is not a new property of the
network: copyparty's admin password and RomM's API tokens already traverse the
same hop the same way. The alternative that would have removed it is setting
the route's `proxy.host` to `link`, which would make the backend a true
loopback connection — and it was not taken, because it re-activates `link` as a
publication proxy in the middle of the `impa` ingress cutover, which the
service publication runbook explicitly warns against. Reconsider it once the
cutover is finished and Link's connector has been retired, not before.

**`cheevos_token` is a live credential sitting in a plaintext config file.**
The live `retroarch.cfg` on `link` holds a real, non-empty RetroAchievements
token. That is one of the reasons `cloud_sync_sync_configs` stays off: the
config category would carry `retroarch.cfg` itself to every client, moving that
credential onto an iOS device and an Android handheld for no benefit, on top of
fighting Nix for ownership of the file. It is also why the config import path
strips keys by an exact known-secret list rather than by matching on
`password|token|key`, which false-positives on eleven entirely benign input and
keyboard settings while still, on its own, telling you nothing about entropy.

**Unmanaged clients are held to the policy by procedure, not by evaluation.**
Only `link` is Nix-managed; the iOS and Android clients get generated artifacts
and a validation report, and a human applies them. Nothing detects an unmanaged
client that has drifted — a core swapped, a sort setting flipped, a path
retyped — until a save lands in the wrong remote directory. Every RetroArch
update on those two devices is therefore a compatibility event with a checklist
attached, and that checklist is the only enforcement there is.

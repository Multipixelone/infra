# Marin Caldera Music Headless

Marin uses the native `caldera-headless` package when
`services.marin.headlessPlayer = "caldera"`. The alternative values are
`"plexamp"` (rollback) and `"none"`. Plexamp's package, service definition,
and `/var/lib/plexamp-headless` state are retained but inactive while Caldera is
selected.

## Provenance and updates

The package is Caldera Music Headless **1.0.47** from:

```
https://releases.caldera.homes/music/headless/latest/caldera-music-linux-x86_64.tar.gz
sha256-tJfm8X2LTy4fepVFTyNvjfDMijaAXqv9c6zzKryv0JA=
```

The publisher's URL is mutable; the Nix fixed-output hash pins the accepted
contents. Update only by changing the version, URL if a versioned artifact is
published, and hash together after inspecting the new archive. The payload is
an unfree native binary. The operator has accepted its redistribution to this
private infrastructure's Attic cache; do not treat that as public redistribution
permission.

The package installs only the ELF and required bundled FFmpeg libraries under
the immutable Nix store. It intentionally omits the upstream `upgrade.sh` and
installer wrapper. Upstream's updater replaces `$HOME/caldera-music`; it cannot
replace `$out`, and the user service always executes the Nix-store launcher.
Do not create a writable `$HOME/caldera-music` installation. Package upgrades
are Nix version/hash changes, not Caldera self-updates.

## Bootstrap and audio device selection

Caldera is a globally installed systemd _user_ service, gated to the lingering
`tunnel` user. This gives it the same PipeWire/ALSA `default` endpoint as
`tunnel`'s working audio services. State, configuration, cache, and
authentication remain under `/var/lib/caldera-headless`, owned by `tunnel:users`
with a `0700` state root. The helpers stop the service through `tunnel`'s user
manager and acquire the same exclusive lock, then use the same identity,
PipeWire runtime, and `--config` path. Run them from an interactive root shell
or with `sudo`; the login PIN flow is interactive and no token is passed in an
argv, store path, or unit environment.

```console
sudo caldera-headless-list-devices
sudo caldera-headless-set-device '<device-uid>'
sudo caldera-headless-login
sudo systemctl --user --machine=tunnel@.host start caldera-headless.service
sudo systemctl --user --machine=tunnel@.host status caldera-headless.service
```

`caldera-headless-login` uses Caldera's verified `--login --player-name Marin`
interface. `caldera-headless-list-devices` uses `--list-devices`, and
`caldera-headless-set-device` uses `--device`. Restarting is deliberate after a
control operation; inspect the command result before starting the service. The
service is wanted by `default.target`, starts after `pipewire.service` and
`wireplumber.service`, and waits up to 30 seconds for both a default PipeWire
sink and `marin-speaker-unmute.service` before failing with a diagnostic.

## Backup, acceptance, and contention

Back up `/var/lib/caldera-headless` as private credential-bearing state. Do not
copy, merge, or delete `/var/lib/plexamp-headless` during this migration.
On activation, the existing Caldera tree is ownership-migrated to `tunnel:users`;
its existing descendant modes are preserved, while only the state root is set to
`0700`; the now-unused `caldera-headless` account and group are then removed.
Review the state ownership after the first switch if it contains mounts or files
intentionally owned by another account. Credentials remain mutable state and
must not be placed in Nix, the Nix store, or unit environments.

After a deployment and bootstrap, use low volume and verify all of the
following live:

1. `systemctl --user --machine=tunnel@.host status caldera-headless` is healthy
   and Caldera appears as Marin in Plex clients.
2. Playback reaches Marin's CS4208 speaker output after
   `marin-speaker-unmute.service`; test play, pause, queue changes, and restart.
3. The selected device UID remains usable while Snapclient/PipeWire are idle
   and while they are active. Caldera now shares `tunnel`'s PipeWire graph and
   default endpoint, so inspect contention there rather than assuming direct
   ALSA exclusivity. Stop a competing player rather than forcing two players to
   control the same output.
4. Confirm the actual listeners and interfaces with `ss -lntup` and firewall
   counters. The configuration opens only statically evidenced TCP 32500
   (Plex Companion) and UDP 32412 (GDM discovery). It intentionally does not
   open Xita UDP 9999 until its enabled state, audience, and multihomed exposure
   are verified on Marin.

## Rollback

Change `services.marin.headlessPlayer` to `"plexamp"`, rebuild Marin through
the normal Nix workflow, and claim/start Plexamp using its existing helper if
needed. The selector gates users, services, helpers, firewall rules, and system
packages, and is the primary mutual-exclusion mechanism because Plexamp remains
a system service while Caldera is a user service. Rollback does not alter either
player's state directory.

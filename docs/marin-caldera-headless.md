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
replace `$out`, and the system service always executes the Nix-store launcher.
Do not create a writable `$HOME/caldera-music` installation for the service
user. Package upgrades are Nix version/hash changes, not Caldera self-updates.

## Bootstrap and audio device selection

Caldera state, configuration, cache, and authentication are private to the
`caldera-headless` user under `/var/lib/caldera-headless`. The helpers stop the
daemon and acquire the same exclusive lock as the service, then use the same
user and `--config` path. Run them from an interactive root shell or with
`sudo`; the login PIN flow is interactive and no token is passed in an argv,
store path, or unit environment.

```console
sudo caldera-headless-list-devices
sudo caldera-headless-set-device '<ALSA-device-uid>'
sudo caldera-headless-login
sudo systemctl start caldera-headless.service
```

`caldera-headless-login` uses Caldera's verified `--login --player-name Marin`
interface. `caldera-headless-list-devices` uses `--list-devices`, and
`caldera-headless-set-device` uses `--device`. Restarting is deliberate after a
control operation; inspect the command result before starting the service.

## Backup, acceptance, and contention

Back up `/var/lib/caldera-headless` as private credential-bearing state. Do not
copy, merge, or delete `/var/lib/plexamp-headless` during this migration.

After a deployment and bootstrap, use low volume and verify all of the
following live:

1. `systemctl status caldera-headless` is healthy and Caldera appears as Marin
   in Plex clients.
2. Playback reaches Marin's CS4208 speaker output after
   `marin-speaker-unmute.service`; test play, pause, queue changes, and restart.
3. The selected ALSA device remains usable while Snapclient/PipeWire are idle
   and while they are active. Stop the competing player rather than forcing two
   processes to hold the same exclusive device.
4. Confirm the actual listeners and interfaces with `ss -lntup` and firewall
   counters. The configuration opens only statically evidenced TCP 32500
   (Plex Companion) and UDP 32412 (GDM discovery). It intentionally does not
   open Xita UDP 9999 until its enabled state, audience, and multihomed exposure
   are verified on Marin.

## Rollback

Change `services.marin.headlessPlayer` to `"plexamp"`, rebuild Marin through
the normal Nix workflow, and claim/start Plexamp using its existing helper if
needed. The selector gates users, services, helpers, firewall rules, and system
packages; the services also conflict as a same-manager safeguard. Rollback does
not alter either player's state directory.

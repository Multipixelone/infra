############################################################################
#
#  Nix commands related to the local machine
#
############################################################################

rebuild:
  genswitch

deploy:
  genswitch
  attic push system /run/current-system -j 2

# Every node carries its own name as a tag, so a bare host name is a valid
# selector. The hive sets `allowApplyAll = false`, so there is deliberately no
# filterless recipe: a fleet-wide deploy has to be typed out by hand.
[doc("Deploy one host.")]
colmena-apply host:
  colmena apply --on {{host}}

# Every always-on server, in one go.
colmena-apply-servers:
  colmena apply --on @server

colmena-apply-tag tag:
  colmena apply --on @{{tag}}

# Evaluate + build one host's closure locally without touching it.
colmena-build host:
  colmena build --on {{host}}

# Say what would start/stop/restart on the target; changes nothing.
colmena-dry host:
  colmena apply dry-activate --on {{host}}

# Only works while the target's *current* closure is still in the local store —
# nvd reads both sides locally, so a host last built on another machine (or
# since garbage-collected) fails with a confusing "does not exist" rather than a
# clear error.
[doc("What actually changes on the target, package by package.")]
colmena-diff host:
  #!/usr/bin/env bash
  set -euo pipefail
  colmena build --on {{host}} --keep-result
  # command substitution, NOT process substitution — nvd needs a real store path
  nvd diff "$(ssh colmena.{{host}} readlink -f /run/current-system)" ./.gcroots/node-{{host}}

# Fail-closed split-DNS/service publication deployment. Modes: apply, plan-only.
deploy-services mode="apply" routes="":
  nix run .#service-publication-deploy -- "{{mode}}" "{{routes}}"

services-smoke context="lan" routes="":
  nix run .#service-publication-smoke -- "{{context}}" "{{routes}}"

services-tofu action="plan":
  nix run .#service-publication-tofu -- "{{action}}"

fastb:
  nix-fast-build --attic-cache system --no-link

# Build a standalone home-manager activation package locally
hm-build host:
  nix build .#homeConfigurations.{{host}}.activationPackage

# Build locally, copy closure to the target, and activate over SSH.
# Nix is not on the non-interactive SSH PATH on DSM, so we pin remote-program
# and prepend the nix bindir before invoking activate. Default points at the
# multi-user daemon profile used by synology-nix-installer.
hm-deploy host remote_nix_bindir="/nix/var/nix/profiles/default/bin":
  #!/usr/bin/env bash
  set -euo pipefail
  out=$(nix build .#homeConfigurations.{{host}}.activationPackage --print-out-paths --no-link)
  nix copy --to "ssh://{{host}}?remote-program={{remote_nix_bindir}}/nix-store" "$out"
  ssh {{host}} "PATH={{remote_nix_bindir}}:\$PATH '$out/activate'"

iso:
  nix build .#nixosConfigurations.iso.config.system.build.isoImage

# See docs/new-host.md for the full procedure, including agenix recipient
# enrolment. `modules/<host>/facter.nix` must already exist and point at
# `./facter.json`; nixos-anywhere writes the report this recipe names.
[doc("Install NixOS on a machine already booted into the installer.")]
install host ssh_target:
  nix run .#nixos-anywhere -- \
    --flake .#{{host}} \
    --generate-hardware-config nixos-facter modules/{{host}}/facter.json \
    root@{{ssh_target}}

# Activate a nix-darwin host. Run on the Mac itself.
darwin-switch host=`hostname -s`:
  sudo darwin-rebuild switch --flake .#{{host}}
  # Config-only edits to skhdrc don't bump the launchd plist, so the agent keeps
  # running the old config. Kick it so changes take effect.
  -launchctl kickstart -k gui/$(id -u)/org.nixos.skhd

# (Re)grant macOS Accessibility + Input Monitoring to the hotkey daemon, then
# restart it. skhd runs straight from the nix store; its store path — and thus
# the TCC grant keyed on it — is stable across normal `darwin-switch`es and only
# changes when skhd itself is updated. So this is a one-time step, repeated only
# after such a version bump. Toggle skhd on in the pane that opens, then the
# restart picks it up.
darwin-perms:
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
  -launchctl kickstart -k gui/$(id -u)/org.nixos.skhd

# First-time activation on a fresh Mac, before nix-darwin's darwin-rebuild
# exists on PATH. Run on the Mac itself.
darwin-bootstrap host=`hostname -s`:
  sudo nix run nix-darwin -- switch --flake .#{{host}}

debug:
	genswitch -v -- --show-trace

[parallel]
update: update-flake update-addons

update-flake:
	nix flake update

update-addons:
	nix run 'git+https://git.sr.ht/~rycee/mozilla-addons-to-nix' \
	  --option allow-import-from-derivation true \
	  -- pkgs/firefox-addons/addons.json pkgs/firefox-addons/generated.nix

history:
	nix profile history --profile /nix/var/nix/profiles/system

gc:
	# remove all generations older than 7 days
	sudo nix profile wipe-history --profile /nix/var/nix/profiles/system  --older-than 7d

	# garbage collect all unused nix store entries
	sudo nix store gc --debug
	sudo nix-collect-garbage --delete-old

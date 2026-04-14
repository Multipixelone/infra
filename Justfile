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

colmena-apply:
  colmena apply

colmena-apply-tag tag:
  colmena apply --on @{{tag}}

minishb:
  # nix build .#nixosConfigurations.minish.config.system.build.toplevel
  # attic push system result -j 3
  # nix build .#nixosConfigurations.marin.config.system.build.toplevel
  nh os build -H marin
  attic push system result -j 3
  # nix build .#nixosConfigurations.zelda.config.system.build.toplevel
  nh os build -H zelda
  attic push system result -j 3
  unlink result

fastb:
  nix-fast-build --attic-cache system --no-link

iso:
  nix build .#nixosConfigurations.iso.config.system.build.isoImage

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

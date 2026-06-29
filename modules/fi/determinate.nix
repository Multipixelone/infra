{ inputs, config, ... }:
{
  # Determinate Nix manages /etc/nix on this host instead of nix-darwin.
  # `determinate.darwinModules.default` forces `nix.enable = false` (so
  # nix-darwin no longer writes /etc/nix/nix.conf) and exposes Determinate's
  # own declarative surface under `determinateNix.*`, which writes
  # /etc/nix/nix.custom.conf and /etc/determinate/config.json. This keeps the
  # store intact (no reinstall) while everything below stays in the flake.
  configurations.darwin.fi.module = {
    imports = [ inputs.determinate.darwinModules.default ];

    determinateNix = {
      # `enable` defaults to true once the module is imported; spelled out here
      # so the intent is visible at the host level.
      enable = true;

      # Custom Nix settings -> /etc/nix/nix.custom.conf. Determinate already
      # turns on nix-command + flakes and trusts cache.nixos.org / the FlakeHub
      # cache, so these are all `extra-*` (additive) to avoid clobbering its
      # defaults. Substituters reuse the repo-wide `caches` aggregate
      # (modules/nixpkgs/substituters.nix) so the Mac stays in sync with the
      # NixOS hosts and the flake's own nixConfig.
      customSettings = {
        extra-experimental-features = [ "pipe-operators" ];
        trusted-users = [
          "@admin"
          config.flake.meta.owner.username
        ];
        extra-substituters = map (c: c.url) config.caches;
        extra-trusted-public-keys = map (c: c.key) config.caches;
      };
    };
  };

  flake-file.inputs.determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
}

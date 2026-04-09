{ lib, config, ... }:
{
  options.caches = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          url = lib.mkOption { type = lib.types.str; };
          key = lib.mkOption { type = lib.types.str; };
        };
      }
    );
    default = [ ];
    description = "Binary cache substituters with their public keys.";
  };

  config = {
    caches = [
      {
        url = "https://attic-cache.fly.dev/system?priority=50";
        key = "system:XwpCBI5UHFzt9tEmiq3v8S062HvTqWPUwBR8PoHSfSk=";
      }
      {
        url = "https://nix-community.cachix.org";
        key = "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=";
      }
    ];

    flake.modules.nixos.base = {
      nix.settings = {
        substituters = map (c: c.url) config.caches;
        trusted-public-keys = map (c: c.key) config.caches;
      };
    };
  };
}

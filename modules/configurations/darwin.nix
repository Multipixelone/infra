{
  lib,
  config,
  inputs,
  ...
}:
{
  options.configurations.darwin = lib.mkOption {
    type = lib.types.lazyAttrsOf (
      lib.types.submodule {
        options = {
          module = lib.mkOption {
            type = lib.types.deferredModule;
            description = "Host-specific nix-darwin module.";
          };
        };
      }
    );
    default = { };
    description = ''
      nix-darwin (Apple Silicon / macOS) host configurations.
      Each entry produces a `flake.darwinConfigurations.<name>` output
      activated with `darwin-rebuild switch --flake .#<name>`.
    '';
  };

  config.flake-file.inputs.nix-darwin = {
    url = "github:nix-darwin/nix-darwin/master";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  config.flake = {
    darwinConfigurations = lib.flip lib.mapAttrs config.configurations.darwin (
      _name: { module, ... }: inputs.nix-darwin.lib.darwinSystem { modules = [ module ]; }
    );

    checks =
      config.flake.darwinConfigurations
      |> lib.mapAttrsToList (
        name: darwin: {
          ${darwin.config.nixpkgs.hostPlatform.system} = {
            "configurations/darwin/${name}" = darwin.config.system.build.toplevel;
          };
        }
      )
      |> lib.mkMerge;
  };
}

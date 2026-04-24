{
  lib,
  config,
  inputs,
  withSystem,
  ...
}:
{
  options.configurations.homeManager = lib.mkOption {
    type = lib.types.lazyAttrsOf (
      lib.types.submodule {
        options = {
          module = lib.mkOption {
            type = lib.types.deferredModule;
            description = "Host-specific Home Manager module.";
          };
          system = lib.mkOption {
            type = lib.types.str;
            default = "x86_64-linux";
            description = "Target system for this standalone Home Manager configuration.";
          };
        };
      }
    );
    default = { };
    description = ''
      Standalone Home Manager configurations for non-NixOS hosts.
      Each entry produces a `flake.homeConfigurations.<name>` output
      activated with `home-manager switch --flake .#<name>`.
    '';
  };

  config.flake = {
    homeConfigurations = lib.flip lib.mapAttrs config.configurations.homeManager (
      _name:
      { module, system }:
      withSystem system (
        { pkgs, ... }:
        inputs.home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [
            config.flake.modules.homeManager.base
            module
          ];
        }
      )
    );

    checks =
      config.flake.homeConfigurations
      |> lib.mapAttrsToList (
        name: hm: {
          ${hm.pkgs.stdenv.hostPlatform.system} = {
            "configurations/home-manager/${name}" = hm.activationPackage;
          };
        }
      )
      |> lib.mkMerge;
  };
}

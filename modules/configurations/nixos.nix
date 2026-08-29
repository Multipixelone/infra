{ lib, config, ... }:
{
  options.configurations.nixos = lib.mkOption {
    type = lib.types.lazyAttrsOf (
      lib.types.submodule {
        options = {
          module = lib.mkOption {
            type = lib.types.deferredModule;
          };
          deployment = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.submodule {
                options = {
                  targetHost = lib.mkOption {
                    type = lib.types.nullOr lib.types.str;
                    default = null;
                    description = "SSH target hostname or IP address. Defaults to the NixOS hostname if null.";
                  };
                  targetPort = lib.mkOption {
                    type = lib.types.nullOr lib.types.ints.unsigned;
                    default = null;
                    description = "SSH port for colmena deployment. Null uses the standard port or ssh_config.";
                  };
                  targetUser = lib.mkOption {
                    type = lib.types.str;
                    default = "root";
                    description = "SSH user for colmena deployment.";
                  };
                  tags = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                    description = "Colmena tags used to group hosts for targeted deployments.";
                  };
                  allowLocalDeployment = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "Allow colmena to deploy to the local machine.";
                  };
                  buildOnTarget = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "Build the system profile on the target node instead of locally.";
                  };
                  replaceUnknownProfiles = lib.mkOption {
                    type = lib.types.bool;
                    default = true;
                    description = "Allow applying over a profile this colmena has no knowledge of.";
                  };
                  sshOptions = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    default = [ ];
                    description = "Extra options passed to the SSH command colmena runs.";
                  };
                };
              }
            );
            default = null;
            description = "Colmena deployment settings. If null, this host is excluded from the colmena hive.";
          };
        };
      }
    );
  };

  config.flake = {
    nixosConfigurations = lib.flip lib.mapAttrs config.configurations.nixos (
      _name: { module, ... }: lib.nixosSystem { modules = [ module ]; }
    );

    checks =
      config.flake.nixosConfigurations
      |> lib.mapAttrsToList (
        name: nixos: {
          ${nixos.config.nixpkgs.hostPlatform.system} = {
            "configurations/nixos/${name}" = nixos.config.system.build.toplevel;
          };
        }
      )
      |> lib.mkMerge;
  };
}

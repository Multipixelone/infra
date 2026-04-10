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
                  useWireguardAddress = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "When true and targetHost is null, use the host's WireGuard address from the hosts registry for deployment.";
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

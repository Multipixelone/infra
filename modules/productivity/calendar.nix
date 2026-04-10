{ inputs, ... }:
{
  flake.modules = {
    nixos.base = {
    };

    homeManager = {
      base =
        hmArgs@{ lib, pkgs, ... }:
        let
          # wrap secret into gcalcli cli
          gcalcli-wrapped = pkgs.writeShellScriptBin "gcalcli" ''
            ${lib.getExe pkgs.gcalcli} \
            --client-id=$(cat ${hmArgs.config.age.secrets."gcalclient".path}) \
            --client-secret=$(cat ${hmArgs.config.age.secrets."gcalsecret".path}) \
            "$@"
          '';
        in
        {
          age = {
            secrets = {
              "gcalclient" = {
                file = "${inputs.secrets}/gcal/client.age";
              };
              "gcalsecret" = {
                file = "${inputs.secrets}/gcal/secret.age";
              };
            };
          };
          home.packages = [
            gcalcli-wrapped
          ];
        };
      gui = _: {
      };
    };
  };
}

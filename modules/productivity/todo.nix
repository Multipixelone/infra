{ inputs, ... }:
{
  flake.modules = {
    nixos.base = {
    };

    homeManager = {
      base =
        hmArgs@{ lib, pkgs, ... }:
        let
          # wrap secret into todoist
          todoist-wrapped = pkgs.writeShellScriptBin "td" ''
            export TODOIST_TOKEN=$(cat ${hmArgs.config.age.secrets."todoist".path})
            ${lib.getExe pkgs.todoist} "$@"
          '';
        in
        {
          age = {
            secrets = {
              "todoist" = {
                file = "${inputs.secrets}/todoist.age";
              };
            };
          };
          home.packages = [
            todoist-wrapped
          ];
        };
      gui = _: {
      };
    };
  };
}

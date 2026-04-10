{ inputs, ... }:
{
  flake.modules = {
    nixos.base = {
    };

    homeManager = {
      base =
        hmArgs@{ lib, pkgs, ... }:
        let
          # wrap secret into tgpt
          tgpt-wrapped = pkgs.writeShellScriptBin "tgpt" ''
            export AI_PROVIDER="openai"
            export OPENAI_MODEL="gpt-5-nano" # use 5-nano TODO: use bash variable expansion to set this value if unset.
            export OPENAI_API_KEY=$(cat ${hmArgs.config.age.secrets."openai".path})
            ${lib.getExe pkgs.tgpt} "$@"
          '';
        in
        {
          age = {
            secrets = {
              "openai" = {
                file = "${inputs.secrets}/openai.age";
              };
            };
          };
          home.packages = [
            tgpt-wrapped
          ];
        };
      gui = _: {
      };
    };
  };
}

{ inputs, ... }:
{
  flake.modules.nixos.base =
    { config, lib, ... }:
    {
      # Declaration and consumers move together: `nix.extraOptions` is
      # types.lines, so a forced `!include ${config.age.secrets.nix.path}`
      # would still be evaluated with the secret gone.
      config = lib.mkIf (!config.infra.installerMedia) {
        age.secrets = {
          "attic".file = "${inputs.secrets}/attic.age";
          "nix" = {
            file = "${inputs.secrets}/github/nix.age";
            mode = "440";
            owner = "tunnel";
            group = "users";
          };
        };
        nix = {
          settings.netrc-file = config.age.secrets."attic".path;
          extraOptions = ''
            !include ${config.age.secrets.nix.path}
          '';
        };
      };
    };
}

{ inputs, ... }:
{
  flake.modules.nixos.base =
    { pkgs, config, ... }:
    {
      environment.systemPackages = [ pkgs.attic-client ];
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
}

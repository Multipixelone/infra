{
  flake.modules.homeManager.base =
    hmArgs@{
      pkgs,
      lib,
      ...
    }:
    let
      # unpaged bat instead of cat
      bat-wrapped = pkgs.writeShellApplication {
        name = "cat";
        runtimeInputs = [
          hmArgs.config.programs.bat.package
        ];
        text = ''
          bat --style=header -P "$@"
        '';
      };
    in
    {
      programs = {
        fish.shellAliases.cat = lib.getExe bat-wrapped;
        bat = {
          enable = true;
          config = {
            pager = "${lib.getExe pkgs.ov} --quit-if-one-screen --header 3";
          };
          extraPackages = with pkgs.bat-extras; [
            prettybat
            batwatch
            batpipe
            batman
            batdiff
          ];
        };
      };
    };
}

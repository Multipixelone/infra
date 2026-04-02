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
            batman # Read system manual pages (man) using bat as the manual page formatter
            batgrep # Quickly search through and highlight files using ripgrep
            batdiff # Diff a file against the current git index, or display the diff between two files
            batpipe # Less (and soon bat) preprocessor for viewing more types of files in the terminal
            batwatch # Watch for changes in one or more files, and print them with bat
            prettybat # Pretty-print source code
          ];
        };
      };
    };
}

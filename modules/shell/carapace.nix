{
  flake.modules.homeManager.base =
    { lib, pkgs, ... }:
    {
      programs.carapace = {
        enable = true;
      };

      home.packages = with pkgs; [
        carapace-bridge
      ];

      programs.fish.interactiveShellInit = lib.concatStringsSep "\n\n" [
        # fish
        ''
          set -Ux CARAPACE_BRIDGES 'argcomplete,bash,carapace,carapace-bin,clap,click,cobra,complete,fish,inshellisense,kingpin,macro,powershell,urfavecli,yargs,zsh,fzf' # optional
          # set -Ux CARAPACE_ENV 1
          set -Ux CARAPACE_MATCH 1
          set -Ux CARAPACE_NOSPACE '*'
          # set -Ux CARAPACE_MERGEFLAGS 0
          set -Ux CARAPACE_UNFILTERED 1


          # carapace _carapace | source
        ''
      ];
    };
}

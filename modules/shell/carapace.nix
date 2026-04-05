{ inputs, ... }:
{
  flake.modules.homeManager.base =
    { lib, pkgs, ... }:
    {
      programs.carapace = {
        enable = true;
      };
      home.packages = with pkgs; [
        carapace-bridge
        # carapace needs sqlite to query the nix packages db
        sqlite
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
      systemd.user.services.update-programs-sqlite = {
        Unit = {
          Description = "Update programs.sqlite for Carapace tab completion";
        };
        Service = {
          Type = "oneshot";
          ExecStart = pkgs.writeShellScript "update-programs-sqlite" ''
            export PATH="${pkgs.gnutar}/bin:${pkgs.xz}/bin:$PATH"
            mkdir -p ~/.nix-defexpr/channels/nixpkgs

            # Shim so <nixpkgs> resolves through ~/.nix-defexpr/channels
            # without this, comma/nix-shell fail on missing default.nix
            ln -sfn ${inputs.nixpkgs}/default.nix ~/.nix-defexpr/channels/nixpkgs/default.nix

            ${pkgs.curl}/bin/curl -sfL "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz" \
              | tar -xJ -O --wildcards '*/programs.sqlite' > ~/.nix-defexpr/channels/nixpkgs/programs.sqlite.tmp

            mv ~/.nix-defexpr/channels/nixpkgs/programs.sqlite.tmp ~/.nix-defexpr/channels/nixpkgs/programs.sqlite
          '';
        };
      };
      systemd.user.timers.update-programs-sqlite = {
        Unit = {
          Description = "Weekly update of programs.sqlite";
        };
        Timer = {
          OnCalendar = "weekly";
          Persistent = true;
        };
        Install = {
          WantedBy = [ "timers.target" ];
        };
      };
    };
}

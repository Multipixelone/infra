{
  flake.modules.homeManager.base =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.catppuccin.lazygit;
      # The pinned Catppuccin theme puts authorColors under gui; lazygit expects gui.theme.
      theme =
        pkgs.runCommand "lazygit-catppuccin-theme.yml"
          {
            nativeBuildInputs = [ pkgs.yq-go ];
          }
          ''
            yq '.gui.theme.authorColors = .gui.authorColors | del(.gui.authorColors)' \
              ${lib.escapeShellArg "${config.catppuccin.sources.lazygit}/${cfg.flavor}/${cfg.accent}.yml"} > "$out"
          '';
      configDirectory =
        if !pkgs.stdenv.hostPlatform.isDarwin || config.xdg.enable then
          config.xdg.configHome
        else
          "${config.home.homeDirectory}/Library/Application Support";
    in
    {
      home.sessionVariables = lib.mkIf cfg.enable {
        LG_CONFIG_FILE = lib.mkForce (
          lib.concatStringsSep "," (
            [ "${theme}" ]
            ++ lib.optional (config.programs.lazygit.settings != { }) "${configDirectory}/lazygit/config.yml"
          )
        );
      };

      programs = {
        lazygit = {
          enable = true;
          settings = {
            notARepository = "quit";
            disableStartupPopups = true;
            gui = {
              nerdFontsVersion = "3";
              showBranchCommitHash = true;
            };
          };
        };
        delta = {
          enable = true;
          enableGitIntegration = true;
        };
        git = {
          enable = true;
          lfs.enable = true;

          ignores = [
            "*result*"
          ];
          settings = {
            pull = {
              ff = "only";
              rebase = false;
            };
            push = {
              default = "current";
              autoSetupRemote = true;
            };
            mergetool."diffview" = {
              cmd = "nvim -n -c \"DiffviewOpen\" \"$MERGE\"";
              prompt = false;
            };
            init.defaultBranch = "main";
            branch.autosetupmerge = "true";
            repack.usedeltabaseoffset = "true";
            rebase = {
              autoSquash = true;
              autoStash = true;
            };
          };
        };
      };
    };
}

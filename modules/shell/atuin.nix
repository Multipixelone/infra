{ inputs, ... }:
{
  flake.modules.homeManager.base = hmArgs: {
    age.secrets = {
      "atuin" = {
        file = "${inputs.secrets}/atuin.age";
      };
    };
    # Daemon disabled — unreliable with nix-managed shells and direnv workflows
    # (socket lifecycle mismatches, stale processes after rebuilds).
    # To re-enable: set daemon.enable = true, search_mode = "daemon-fuzzy",
    # filter_mode_shell_up_key_binding = "session-preload", and restore
    # the daemon.autostart block below.
    programs.atuin = {
      enable = true;
      enableFishIntegration = true;
      daemon.enable = false;
      settings = {
        update_check = false;

        key_path = hmArgs.config.age.secrets."atuin".path;

        auto_sync = true;
        sync_frequency = "5m";
        sync_address = "https://api.atuin.sh";

        history_filter = [
          "^z(i)? .*"
          "^cd .*"
        ];

        ctrl_n_shortcuts = true;
        enter_accept = true;

        workspaces = true;
        search_mode = "fuzzy";
        filter_mode = "global";
        filter_mode_shell_up_key_binding = "session";

        style = "compact";
        inline_height = 20;

        # daemon = {
        #   autostart = true;
        # };

        ai = {
          enabled = true;
        };
      };
    };
    # Hex PTY proxy — must come before atuin init so the popup
    # renders over output without clearing the terminal.
    programs.fish.interactiveShellInit = hmArgs.lib.mkBefore ''
      ${hmArgs.lib.getExe hmArgs.config.programs.atuin.package} hex init fish | source
    '';
  };
}

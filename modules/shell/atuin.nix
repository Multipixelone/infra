{ inputs, ... }:
{
  flake.modules.homeManager.base = hmArgs: {
    age.secrets = {
      "atuin" = {
        file = "${inputs.secrets}/atuin.age";
      };
    };
    programs.atuin = {
      enable = true;
      enableFishIntegration = true;
      daemon.enable = true;
      settings = {
        update_check = false;

        key_path = hmArgs.config.age.secrets."atuin".path;

        auto_sync = true;
        sync_frequency = "5m";
        sync_address = "https://api.atuin.sh";

        ctrl_n_shortcuts = true;
        enter_accept = true;

        search_mode = "fuzzy";
        filter_mode = "global";
        filter_mode_shell_up_key_binding = "session-preload";

        style = "compact";
        inline_height = 20;

        daemon = {
          enabled = true;
          autostart = true;

          sync_frequency = 3600;
          systemd_socket = true;
        };
      };
    };
  };
}

{
  flake.modules.homeManager.gui = {
    wayland.windowManager.hyprland.settings = {
      workspace_rule = [
        {
          workspace = "5";
          gaps_in = 5;
          gaps_out = 3;
        }
        { workspace = "4"; }
        {
          workspace = "1";
          monitor = "eDP-1";
          default = true;
        }
        {
          workspace = "1";
          monitor = "DP-1";
          default = true;
        }
        {
          workspace = "2";
          monitor = "DP-1";
        }
        {
          workspace = "3";
          monitor = "DP-1";
        }
        {
          workspace = "4";
          monitor = "DP-1";
        }
        {
          workspace = "5";
          monitor = "DP-3";
        }
        {
          workspace = "6";
          monitor = "DP-3";
        }
        {
          workspace = "7";
          monitor = "DP-1";
        }
      ];
    };
  };
}

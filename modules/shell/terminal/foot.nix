{ lib, ... }:
{
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    {
      stylix.targets.foot.enable = false;
      programs.foot = {
        enable = true;
        server.enable = true;
        settings = {
          main = {
            box-drawings-uses-font-glyphs = "yes";
            pad = "4x4 center";
            selection-target = "clipboard";
            font = "PragmataPro Mono Liga:size=11";
          };
          desktop-notifications.command = "${lib.getExe pkgs.libnotify} -a \${app-id} -i \${app-id} \${title} \${body}";
          scrollback = {
            lines = 10000;
            multiplier = 3;
            indicator-position = "relative";
            indicator-format = "line";
          };
          url = {
            launch = "xdg-open \${url}";
            label-letters = "sadfjklewcmpgh";
            osc8-underline = "url-mode";
          };
          cursor = {
            style = "beam";
            beam-thickness = 1;
          };
          colors-dark = {
            alpha = "0.85";
          };
        };
      };
    };
}

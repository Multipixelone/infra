{ inputs, ... }:
{
  flake.modules = {
    homeManager.gui =
      {
        lib,
        pkgs,
        ...
      }:
      {
        programs.hyprlock = {
          enable = true;
          package = inputs.hyprlock.packages.${pkgs.stdenv.hostPlatform.system}.hyprlock;
          settings = {
            general = {
              hide_cursor = false;
              disable_loading_bar = true;
            };
            background = [
              {
                monitor = "";
                path = "screenshot";
                blur_passes = 3;
                blur_size = 8;
              }
            ];
            # label = [
            # time
            # {
            #   monitor = "eDP-1";
            #   text = ''cmd[update:30000] echo "$(date +"%R")"'';
            #   color = "rgb(245, 224, 220)";
            #   font_size = 100;
            #   inherit font_family;
            #   shadow_passes = 4;
            #   shadow_size = 4;
            #   position = "-30, 0";
            #   halign = "right";
            #   valign = "top";
            # }
            # date
            # {
            #   monitor = "eDP-1";
            #   text = ''cmd[update:43200000] echo "$(date +"%A, %d %B %Y")"'';
            #   color = "rgb(245, 224, 220)";
            #   font_size = 45;
            #   inherit font_family;
            #   position = "-30, -140";
            #   halign = "right";
            #   valign = "top";
            # }
            # media information
            # {
            #   monitor = "eDP-1";
            #   text = ''
            #     cmd[update:0:true] ${lib.getExe song-title}
            #   '';
            #   color = "rgb(245, 224, 220)";
            #   font_size = 50;
            #   inherit font_family;
            #   position = "530, -26";
            #   shadow_passes = 18;
            #   shadow_size = 5;
            #   halign = "left";
            #   valign = "top";
            # }
            # artist + album
            # {
            #   monitor = "eDP-1";
            #   text = ''
            #     cmd[update:0:true] ${lib.getExe song-info}
            #   '';
            #   color = "rgb(245, 224, 220)";
            #   font_size = 36;
            #   inherit font_family;
            #   position = "530, -95";
            #   shadow_passes = 18;
            #   shadow_size = 5;
            #   halign = "left";
            #   valign = "top";
            # }
            # ];
            # image = [
            #   {
            #     # album art
            #     monitor = "eDP-1";
            #     path = "/tmp/waybar-mediaplayer-art.jpg";
            #     size = 450;
            #     rounding = 2;
            #     reload_time = 0;
            #     reload_cmd = ''echo "/tmp/waybar-mediaplayer-art"'';
            #     position = "30, -20";
            #     shadow_passes = 4;
            #     shadow_size = 4;
            #     halign = "left";
            #     valign = "top";
            #   }
            # ];
            # input-field = [
            #   {
            #     monitor = "eDP-1";
            #     size = "380, 75";
            #     outline_thickness = 3;
            #     dots_size = 0.33;
            #     dots_spacing = 0.15;
            #     dots_center = "false";
            #     dots_rounding = -1;
            #     outer_color = "rgb(203, 166, 247)";
            #     inner_color = "rgb(49, 50, 68)";
            #     font_color = "rgb(245, 224, 220)";
            #     fade_on_empty = true;
            #     fade_timeout = 1000;
            #     placeholder_text = "<i>Password</i>";
            #     hide_input = false;
            #     rounding = -1;
            #     check_color = "rgb(204, 136, 34)";
            #     fail_color = "rgb(204, 34, 34)";
            #     capslock_color = -1;
            #     numlock_color = -1;
            #     bothlock_color = -1;
            #     invert_numlock = false;
            #     swap_font_color = false;
            #     position = "0, 50";
            #     halign = "center";
            #     valign = "bottom";
            #   }
            # ];
          };
        };
        wayland.windowManager.hyprland = {
          settings = {
            bind = [
              {
                _args = [
                  "SUPER + L"
                  (lib.generators.mkLuaInline ''hl.dsp.exec_cmd("loginctl lock-session")'')
                ];
              }
            ];
          };
        };
      };
  };
}

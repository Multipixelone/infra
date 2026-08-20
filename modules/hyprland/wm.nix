{
  lib,
  inputs,
  ...
}:
{
  caches = [
    {
      url = "https://hyprland.cachix.org";
      key = "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc=";
    }
  ];
  flake.modules = {
    nixos.pc =
      { pkgs, ... }:
      {
        imports = [
          inputs.hyprland.nixosModules.default
        ];
        nixpkgs.overlays = [
          inputs.nur.overlays.default
        ];
        programs.hyprland = {
          enable = true;
          withUWSM = true;
          package = inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
          portalPackage =
            inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.xdg-desktop-portal-hyprland;
        };
        # hint electron apps to run on wayland
        environment.sessionVariables.NIXOS_OZONE_WL = "1";
        security.pam.services.hyprlock.text = "auth include login";
      };
    homeManager.gui =
      hmArgs@{ pkgs, osConfig, ... }:
      let
        inherit (hmArgs.config.lib.stylix) colors;
        hostname = if osConfig != null then osConfig.networking.hostName else null;
        cursor-theme = pkgs.fetchzip {
          url = "https://blusky.s3.us-west-2.amazonaws.com/Posy_Cursor_Black_h.tar.gz";
          hash = "sha256-EC4bKLo1MAXOABcXb9FneoXlV2Fkb9wOFojewaSejZk=";
        };
      in
      {
        # imports = [
        #   ./conf
        #   ./modules
        # ];
        services = {
          ssh-agent.enable = true;
          swayosd.enable = true;
          cliphist = {
            enable = true;
            allowImages = true;
          };
          mako = {
            enable = true;
            settings = {
              # border-color = lib.mkForce "#${colors.base0E}";
              # background-color = lib.mkForce "#${colors.base00}";
              border-radius = 6;
              border-size = 2;
              ignore-timeout = true;
              default-timeout = 5000;
            };
          };
        };
        # TODO reorganize all of this and make it cleaner
        # TODO move all env def into session vars
        home.sessionVariables = {
          QT_QPA_PLATFORM = "wayland";
          SDL_VIDEODRIVER = "wayland";
          XDG_SESSION_TYPE = "wayland";
          QT_AUTO_SCREEN_SCALE_FACTOR = 1;
        };
        systemd.user.targets.tray.Unit.Requires = lib.mkForce [ "graphical-session.target" ];
        wayland.windowManager.hyprland = {
          enable = true;
          configType = "lua";
          # use package definitions from NixOS
          package = null;
          portalPackage = null;
          plugins = [
            # inputs.hyprland-plugins.packages.${pkgs.stdenv.hostPlatform.system}.hyprexpo
          ];
          systemd = {
            enable = false;
            variables = [ "--all" ];
          };
          settings = {
            monitor = lib.mkMerge [
              (lib.mkIf (hostname == "link") [
                # HDR re-enable: add `cm = "hdr"` to advertise HDR colorspace.
                {
                  output = "DP-1";
                  mode = "2560x1440@240";
                  position = "1200x0";
                  scale = 1;
                }
                {
                  output = "DP-3";
                  mode = "1920x1200@60";
                  position = "0x0";
                  scale = 1;
                  transform = 1;
                }
                {
                  output = "HDMI-A-1";
                  disabled = true;
                }
              ])
              (lib.mkIf (hostname == "zelda") [
                {
                  output = "";
                  mode = "highres";
                  position = "auto";
                  scale = 1.333333;
                }
              ])
            ];

            # `exec-once` is gone; startup commands hang off the start event.
            on = [
              {
                _args = [
                  "hyprland.start"
                  (lib.generators.mkLuaInline ''
                    function()
                      hl.exec_cmd("uwsm finalize")
                    end'')
                ];
              }
            ];

            env = [
              {
                _args = [
                  "XDG_SCREENSHOTS_DIR"
                  "/home/tunnel/Pictures/Screenshots"
                ];
              }
              {
                _args = [
                  "QT_QPA_PLATFORMTHEME"
                  "qt5ct"
                ];
              }
              {
                _args = [
                  "XCURSOR_SIZE"
                  "32"
                ];
              }
              {
                _args = [
                  "XDG_CURRENT_DESKTOP"
                  "Hyprland"
                ];
              }
              {
                _args = [
                  "XDG_SESSION_DESKTOP"
                  "Hyprland"
                ];
              }
              {
                _args = [
                  "MOZ_ENABLE_WAYLAND"
                  "1"
                ];
              }
              {
                _args = [
                  "HYPRCURSOR_THEME"
                  "Posy_Cursor_Black_h"
                ];
              }
              {
                _args = [
                  "HYPRCURSOR_SIZE"
                  "24"
                ];
              }
            ];

            # `bezier = name, x1, y1, x2, y2` is now hl.curve with a point list.
            curve = [
              {
                _args = [
                  "wind"
                  {
                    type = "bezier";
                    points = [
                      [
                        0.05
                        0.9
                      ]
                      [
                        0.1
                        1.05
                      ]
                    ];
                  }
                ];
              }
              {
                _args = [
                  "winIn"
                  {
                    type = "bezier";
                    points = [
                      [
                        0.1
                        1.1
                      ]
                      [
                        0.1
                        1.1
                      ]
                    ];
                  }
                ];
              }
              {
                _args = [
                  "winOut"
                  {
                    type = "bezier";
                    points = [
                      [
                        0.3
                        (-0.3)
                      ]
                      [
                        0
                        1
                      ]
                    ];
                  }
                ];
              }
              {
                _args = [
                  "liner"
                  {
                    type = "bezier";
                    points = [
                      [
                        1
                        1
                      ]
                      [
                        1
                        1
                      ]
                    ];
                  }
                ];
              }
            ];

            # `animation = leaf, onoff, speed, curve[, style]` is now a table.
            animation = [
              {
                leaf = "windows";
                enabled = true;
                speed = 4;
                bezier = "wind";
                style = "slide";
              }
              {
                leaf = "windowsIn";
                enabled = true;
                speed = 4;
                bezier = "winIn";
                style = "slide";
              }
              {
                leaf = "windowsOut";
                enabled = true;
                speed = 5;
                bezier = "winOut";
                style = "slide";
              }
              {
                leaf = "windowsMove";
                enabled = true;
                speed = 3;
                bezier = "wind";
                style = "slide";
              }
              {
                leaf = "border";
                enabled = true;
                speed = 1;
                bezier = "liner";
              }
              {
                leaf = "borderangle";
                enabled = true;
                speed = 30;
                bezier = "liner";
                style = "loop";
              }
              {
                leaf = "fade";
                enabled = true;
                speed = 10;
                bezier = "default";
              }
              {
                leaf = "workspaces";
                enabled = true;
                speed = 3;
                bezier = "wind";
              }
            ];

            # Everything that used to be a bare hyprlang section now lives
            # under a single hl.config() call.
            config = {
              animations.enabled = true;
              debug = {
                disable_logs = true;
                full_cm_proto = true; # needed for gamescope
              };
              decoration = {
                rounding = 10;
                shadow = {
                  offset = [
                    1
                    3
                  ];
                  # only enable drop shadow on link
                  enabled = true;
                  range = 30;
                  render_power = 4;
                  color = lib.mkForce "rgba(01010166)";
                  color_inactive = lib.mkForce "rgba(00000022)";
                };
                active_opacity = 1;
                inactive_opacity = 1;
                blur = {
                  enabled = true;
                  xray = true;
                  brightness = 1.1;
                  noise = 0.02;
                  contrast = 1;
                  passes = 4;
                  size = 10;
                  ignore_opacity = true;
                  popups = true;
                  popups_ignorealpha = 0.6;
                };
              };
              general = {
                allow_tearing = true;
                border_size = 0;
                gaps_in = 4;
                gaps_out = 6;
                gaps_workspaces = 20;
                resize_on_border = true;
                "col.inactive_border" = lib.mkForce "rgb(${colors.base00})";
                "col.active_border" = lib.mkForce "rgb(${colors.base0E})";
              };
              ecosystem = {
                no_update_news = true;
                no_donation_nag = true;
              };
              dwindle = {
                # keep floating dimensions while tiling
                preserve_split = true;
              };
              misc = {
                disable_autoreload = true;
                background_color = "rgb(${colors.base00})";
                force_default_wallpaper = 0;
                disable_hyprland_logo = true;
                disable_splash_rendering = true;
                animate_manual_resizes = true;
                key_press_enables_dpms = true;
                mouse_move_enables_dpms = true;
              };
              render = lib.mkIf (hostname == "link") {
                direct_scanout = true;
              };
              cursor = {
                persistent_warps = true;
                inactive_timeout = 5;
                default_monitor = "DP-1";
              };
              input = {
                accel_profile = "flat";
                touchpad = {
                  natural_scroll = true;
                  disable_while_typing = true;
                  scroll_factor = 0.5;
                };
              };
              xwayland = {
                force_zero_scaling = true;
              };
              binds = {
                allow_workspace_cycles = true;
              };
            };
          };
        };
        home.file.".local/share/icons/Posy_Cursor_Black_h".source = cursor-theme;
      };
  };
}

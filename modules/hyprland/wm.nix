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
          extraConfig = ''
            animations {
                enabled = true
                # Animation curves
                bezier = wind, 0.05, 0.9, 0.1, 1.05
                bezier = winIn, 0.1, 1.1, 0.1, 1.1
                bezier = winOut, 0.3, -0.3, 0, 1
                bezier = liner, 1, 1, 1, 1
                animation = windows, 1, 4, wind, slide
                animation = windowsIn, 1, 4, winIn, slide
                animation = windowsOut, 1, 5, winOut, slide
                animation = windowsMove, 1, 3, wind, slide
                animation = border, 1, 1, liner
                animation = borderangle, 1, 30, liner, loop
                animation = fade, 1, 10, default
                animation = workspaces, 1, 3, wind
            }
          '';
          settings = {
            # FIX Kinda jank mkMerge
            monitorSettings = lib.mkMerge [
              (lib.mkIf (hostname == "link") {
                monitor = [
                  # HDR re-enable: append ",cm,hdr" to advertise HDR colorspace.
                  "DP-1,2560x1440@240,1200x0,1"
                  "DP-3,1920x1200@60,0x0,1,transform,1"
                  "HDMI-A-1,disabled"
                ];
              })
              (lib.mkIf (hostname == "zelda") { monitor = [ ",highres,auto,1.333333" ]; })
            ];
            exec-once = [
              "uwsm finalize"
            ];
            debug = {
              disable_logs = true;
              full_cm_proto = true; # needed for gamescope
            };
            env = [
              "XDG_SCREENSHOTS_DIR,/home/tunnel/Pictures/Screenshots"
              "QT_QPA_PLATFORMTHEME,qt5ct"
              "XCURSOR_SIZE,32"
              "XDG_CURRENT_DESKTOP,Hyprland"
              "XDG_SESSION_DESKTOP,Hyprland"
              "MOZ_ENABLE_WAYLAND,1"
              "HYPRCURSOR_THEME,Posy_Cursor_Black_h"
              "HYPRCURSOR_SIZE,24"
            ];
            decoration = {
              rounding = "10";
              shadow = {
                offset = "1 3";
                # only enable drop shadow on link
                enabled = true;
                range = 30;
                render_power = 4;
                color = lib.mkForce "rgba(01010166)";
                color_inactive = lib.mkForce "0x22000000";
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
                size = 7;
                ignore_opacity = true;
                popups = true;
                popups_ignorealpha = 0.6;
              };
              #"col.shadow" = "rgba(00000099)";
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
            # gestures = {
            #   workspace_swipe = true;
            #   workspace_swipe_forever = true;
            #   workspace_swipe_cancel_ratio = 0.15;
            #   workspace_swipe_create_new = true;
            # };
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
        home.file.".local/share/icons/Posy_Cursor_Black_h".source = cursor-theme;
      };
  };
}

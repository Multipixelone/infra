{ lib, ... }:
{
  flake.modules.homeManager.gui = {
    wayland.windowManager.hyprland.settings = {
      window_rule = [
        # workspace rules
        {
          match.title = "^(Spotify( Premium)?)$";
          workspace = "5 silent";
        }
        {
          match.class = "^(Plexamp)$";
          workspace = "5 silent";
        }
        {
          match.class = "^(vlc)$";
          workspace = "5 silent";
        }
        {
          match.class = "^(mpd)$";
          workspace = "5 silent";
        }
        {
          match.class = "^(com.rafaelmardojai.Blanket)$";
          workspace = "5 silent";
        }
        {
          match.class = "^(obsidian)$";
          workspace = "4 silent";
        }
        {
          match.class = "^(bluebubbles)$";
          workspace = "6 silent";
        }
        {
          match.class = "^(discord)$";
          workspace = "6 silent";
        }
        # center dialogs
        {
          match.title = "^(Open File)(.*)$";
          center = true;
        }
        {
          match.title = "^(Select a File)(.*)$";
          center = true;
        }
        {
          match.title = "^(Choose wallpaper)(.*)$";
          center = true;
        }
        {
          match.title = "^(Open Folder)(.*)$";
          center = true;
        }
        {
          match.title = "^(Save As)(.*)$";
          center = true;
        }
        {
          match.title = "^(Library)(.*)$";
          center = true;
        }
        {
          match.title = "^(File Upload)(.*)$";
          center = true;
        }
        {
          match.class = "^(gcr-prompter)$";
          dim_around = true;
        }
        {
          match.class = "^(xdg-desktop-portal-gtk)$";
          dim_around = true;
        }
        {
          match.class = "^(polkit-gnome-authentication-agent-1)$";
          dim_around = true;
        }
        # idle inhibit while watching videos
        {
          match.class = "^(mpv|.+exe|celluloid)$";
          idle_inhibit = "focus";
        }
        {
          match = {
            class = "^(firefox)$";
            title = "^(.*YouTube.*)$";
          };
          idle_inhibit = "focus";
        }
        {
          match.title = "^(Zoom Meeting)$";
          idle_inhibit = "always";
        }
        {
          match.class = "^(firefox)$";
          idle_inhibit = "fullscreen";
        }
        # idle inhibit while pdf reader open
        {
          match.class = "^(org.kde.okular)$";
          idle_inhibit = "always";
        }
        {
          match.class = "^(org.pwmt.zathura)$";
          idle_inhibit = "always";
        }
        # float rules
        {
          match.class = "^(Plexamp)$";
          float = true;
        }
        {
          match.class = "^(com.rafaelmardojai.Blanket)$";
          float = true;
        }
        {
          match.class = "^(vlc)$";
          float = true;
        }
        {
          match.class = "^(mpd)$";
          float = true;
        }
        {
          match.title = "^(Spotify( Premium)?)$";
          float = true;
        }
        {
          match.class = "^(nm-applet)$";
          float = true;
        }
        {
          match.class = "^(foot-files)$";
          float = true;
        }
        ## app specific rules
        # reaper dropdowns
        {
          match.class = "REAPER";
          no_anim = true;
        }
        {
          match = {
            class = "REAPER";
            title = "^$";
          };
          no_focus = true;
        }
        # firefox pin pip
        {
          match.title = "^(Picture-in-Picture)$";
          float = true;
          pin = true;
        }
        # qalculate
        {
          match.class = "^(qalculate-gtk)$";
          float = true;
          pin = true;
          move = [
            "100%-40%"
            "10%"
          ];
        }
        # pin ripdrag
        {
          match.class = "^(it.catboy.ripdrag)$";
          pin = true;
        }
        ## gaming rules
        # moonlight / gamescope rules
        {
          match.class = "^(moonlight-qt)$";
          workspace = "name:gaming silent";
          fullscreen = true;
          immediate = true;
        }
        {
          match.class = "^(gamescope)$";
          fullscreen = true;
          immediate = true;
        }
        # steam rules
        {
          match.class = "^(steam)$";
          workspace = "name:gaming silent";
        }
        {
          match.title = "^(Steam Big Picture Mode)$";
          fullscreen = true;
          idle_inhibit = "always";
        }
        {
          match.class = "^(steam)$";
          idle_inhibit = "focus";
        }
        {
          match = {
            class = "^(steam)$";
            title = "^(Friends List)$";
          };
          float = true;
          size = [
            500
            1225
          ];
        }
        {
          match = {
            class = "^(steam)$";
            title = "^(Steam Settings)$";
          };
          float = true;
        }
        # steam game rules
        {
          match.class = "^(steam_app_.*)$";
          workspace = "name:gaming silent";
        }
        {
          match.class = "^(steam_app_)(.*)$";
          immediate = true;
          fullscreen = true;
        }
        {
          match.class = "^(cs2)$";
          immediate = true;
        }
        {
          match.class = "^(dota2)$";
          immediate = true;
        }
        {
          match.class = "^(steam_app_.*)$";
          idle_inhibit = "always";
        }
        # minecraft
        {
          match.class = "^(org.prismlauncher.*)$";
          workspace = "name:gaming silent";
        }
        {
          match.class = "^(Minecraft)$";
          workspace = "name:gaming silent";
        }
        # looking-glass-client
        {
          match.class = "looking-glass-client";
          workspace = "name:gaming";
          fullscreen = true;
        }
        # gw2
        {
          match.title = "^(Guild Wars 2( Launcher)?)$";
          workspace = "name:gaming silent";
        }
        {
          match = {
            class = "^(.+exe)$";
            title = "^(Guild Wars 2( Launcher)?)(.*)$";
          };
          workspace = "name:gaming silent";
        }
        {
          match.title = "^(Guild Wars 2)$";
          border_size = 0;
          opaque = true;
          no_blur = true;
          no_shadow = true;
          rounding = 0;
        }
        # blish hud
        {
          match.title = "^(Blish HUD)$";
          no_blur = true;
          float = true;
          center = true;
          no_focus = true;
          no_initial_focus = true;
          border_size = 0;
          pin = true;
          opacity = "0.10 0.10";
        }
      ];
      layer_rule =
        let
          toRegex = list: "^(${lib.concatStringsSep "|" list})$";

          lowopacity = [
            "bar"
            "swaync-notification-window"
            "swaync-control-center"
            "calendar"
            "notifications"
            "system-menu"
          ];

          highopacity = [
            "anyrun"
            "osd"
            "logout_dialog"
            "quickshell:sidebar"
          ];

          blurred = lib.concatLists [
            lowopacity
            highopacity
          ];
        in
        [
          {
            match.namespace = toRegex blurred;
            blur = true;
          }
          {
            match.namespace = "^quickshell.*$";
            blur_popups = true;
          }
          {
            match.namespace = toRegex [
              "bar"
              "quickshell:bar"
            ];
            xray = true;
          }
          {
            match.namespace = toRegex (highopacity ++ [ "music" ]);
            ignore_alpha = 0.5;
          }
          {
            match.namespace = toRegex lowopacity;
            ignore_alpha = 0.2;
          }
          {
            match.namespace = toRegex [
              "notifications"
              "quickshell:notifications:overlay"
              "quickshell:notifictaions:panel"
            ];
            no_anim = true;
          }
        ];
    };
  };
}

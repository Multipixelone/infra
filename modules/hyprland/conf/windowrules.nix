{ lib, ... }:
{
  flake.modules.homeManager.gui = {
    wayland.windowManager.hyprland.settings = {
      windowrule = [
        # workspace rules
        "match:title ^(Spotify( Premium)?)$, workspace 5 silent"
        "match:class ^(Plexamp)$, workspace 5 silent"
        "match:class ^(vlc)$, workspace 5 silent"
        "match:class ^(mpd)$, workspace 5 silent"
        "match:class ^(com.rafaelmardojai.Blanket)$, workspace 5 silent"
        "match:class ^(obsidian)$, workspace 4 silent"
        "match:class ^(bluebubbles)$, workspace 6 silent"
        "match:class ^(discord)$, workspace 6 silent"

        # center dialogs
        "match:title ^(Open File)(.*)$, center on"
        "match:title ^(Select a File)(.*)$, center on"
        "match:title ^(Choose wallpaper)(.*)$, center on"
        "match:title ^(Open Folder)(.*)$, center on"
        "match:title ^(Save As)(.*)$, center on"
        "match:title ^(Library)(.*)$, center on"
        "match:title ^(File Upload)(.*)$, center on"

        "match:class ^(gcr-prompter)$, dim_around on"
        "match:class ^(xdg-desktop-portal-gtk)$, dim_around on"
        "match:class ^(polkit-gnome-authentication-agent-1)$, dim_around on"

        # idle inhibit while watching videos
        "match:class ^(mpv|.+exe|celluloid)$, idle_inhibit focus"
        "match:class ^(firefox)$, match:title ^(.*YouTube.*)$, idle_inhibit focus"
        "match:title ^(Zoom Meeting)$, idle_inhibit always"
        "match:class ^(firefox)$, idle_inhibit fullscreen"

        # idle inhibit while pdf reader open
        "match:class ^(org.kde.okular)$, idle_inhibit always"
        "match:class ^(org.pwmt.zathura)$, idle_inhibit always"

        # float rules
        "match:class ^(Plexamp)$, float on"
        "match:class ^(com.rafaelmardojai.Blanket)$, float on"
        "match:class ^(vlc)$, float on"
        "match:class ^(mpd)$, float on"
        "match:title ^(Spotify( Premium)?)$, float on"
        "match:class ^(nm-applet)$, float on"
        "match:class ^(foot-files)$, float on"

        ## app specific rules
        # reaper dropdowns
        "match:class REAPER, no_anim on"
        "match:class REAPER, match:title ^$, no_focus on"

        # firefox pin pip
        "match:title ^(Picture-in-Picture)$, float on"
        "match:title ^(Picture-in-Picture)$, pin on"

        # qalculate
        "match:class ^(qalculate-gtk)$, float on"
        "match:class ^(qalculate-gtk)$, pin on"
        "match:class ^(qalculate-gtk)$, move 100%-40% 10%"

        # pin ripdrag
        "match:class ^(it.catboy.ripdrag)$, pin on"

        ## gaming rules
        # moonlight / gamescope rules
        "match:class ^(moonlight-qt)$, workspace 7 silent"
        "match:class ^(moonlight-qt)$, fullscreen on"
        "match:class ^(moonlight-qt)$, immediate on"
        "match:class ^(gamescope)$, fullscreen on"
        "match:class ^(gamescope)$, immediate on"

        # steam rules
        "match:class ^(steam)$, workspace 7 silent"
        "match:title ^(Steam Big Picture Mode)$, fullscreen on"
        "match:title ^(Steam Big Picture Mode)$, idle_inhibit always"
        "match:class ^(steam)$, idle_inhibit focus"

        "match:class ^(steam)$, match:title ^(Friends List)$, float on"
        "match:class ^(steam)$, match:title ^(Friends List)$, size 500 1225"
        "match:class ^(steam)$, match:title ^(Steam Settings)$, float on"

        # steam game rules
        "match:class ^(steam_app_.*)$, workspace 7 silent"
        "match:class ^(steam_app_)(.*)$, immediate on"
        "match:class ^(steam_app_)(.*)$, fullscreen on"
        "match:class ^(cs2)$, immediate on"
        "match:class ^(dota2)$, immediate on"
        "match:class ^(steam_app_.*)$, idle_inhibit always"

        # minecraft
        "match:class ^(org.prismlauncher.*)$, workspace 7 silent"
        "match:class ^(Minecraft)$, workspace 7 silent"

        # looking-glass-client
        "match:class looking-glass-client, workspace 7"
        "match:class looking-glass-client, fullscreen on"

        # gw2
        "match:title ^(Guild Wars 2)$, border_size 0"
        "match:title ^(Guild Wars 2)$, opaque on"
        "match:title ^(Guild Wars 2)$, no_blur on"
        "match:title ^(Guild Wars 2)$, no_shadow on"
        "match:title ^(Guild Wars 2)$, rounding 0"

        # blish hud
        "match:title ^(Blish HUD)$, no_blur on"
        "match:title ^(Blish HUD)$, float on"
        "match:title ^(Blish HUD)$, center on"
        "match:title ^(Blish HUD)$, no_focus on"
        "match:title ^(Blish HUD)$, no_initial_focus on"
        "match:title ^(Blish HUD)$, border_size 0"
        "match:title ^(Blish HUD)$, pin on"
        "match:title ^(Blish HUD)$, opacity 0.10 0.10"
      ];
      layerrule =
        let
          toRegex =
            list:
            let
              elements = lib.concatStringsSep "|" list;
            in
            "match:namespace ^(${elements})$";

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
          "${toRegex blurred}, blur true"
          "match:namespace ^quickshell.*$, blur_popups true"
          "${
            toRegex [
              "bar"
              "quickshell:bar"
            ]
          }, xray true"
          "${toRegex (highopacity ++ [ "music" ])}, ignore_alpha 0.5"
          "${toRegex lowopacity}, ignore_alpha 0.2"
          "${
            toRegex [
              "notifications"
              "quickshell:notifications:overlay"
              "quickshell:notifictaions:panel"
            ]
          }, no_anim true"
        ];
    };
  };
}

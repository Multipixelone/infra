{
  inputs,
  lib,
  withSystem,
  ...
}:
{
  flake.modules = {
    homeManager.gui =
      {
        osConfig,
        pkgs,
        config,
        ...
      }:
      let
        terminal = lib.getExe pkgs.foot;
        brightness = lib.getExe pkgs.brillo;
        playerctl = lib.getExe pkgs.playerctl;
        swayosd-client = lib.getExe' pkgs.swayosd "swayosd-client";
        wl-copy = lib.getExe' pkgs.wl-clipboard "wl-copy";
        hyprlandPkg =
          if osConfig != null then
            osConfig.programs.hyprland.package
          else
            inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
        grimblast = pkgs.grimblast.override { hyprland = hyprlandPkg; };
        screenshot-area = withSystem pkgs.stdenv.hostPlatform.system (
          psArgs: psArgs.config.packages.screenshot-area
        );
        screenshot-area-ocr = withSystem pkgs.stdenv.hostPlatform.system (
          psArgs: psArgs.config.packages.screenshot-area-ocr
        );
      in
      {
        wayland.windowManager.hyprland = {
          extraConfig = ''
            bind=ALT_SHIFT, P, submap, passthrough
            submap=passthrough
            bind=, escape, submap, reset
            submap=reset
          '';
          settings = {
            gesture = [
              "3, horizontal, workspace"
            ];
            "$mod" = "ALT";
            bind =
              let
                # this cool setup stolen from Aylur (https://github.com/Aylur/dotfiles/blob/7c4d6a708d426cb1a35a0f1776c4edc52ae1841c/home-manager/hyprland.nix)
                binding =
                  mod: cmd: key: arg:
                  "${mod}, ${key}, ${cmd}, ${arg}";
                mvfocus = binding "ALT" "movefocus";
                resizeactive = binding "Alt_Super" "resizeactive";
                mvwindow = binding "Alt_Shift" "movewindow";
                # borrowed (read: stolen) from fufexan <3 (https://github.com/fufexan/dotfiles/blob/5d5631f475d892e1521c45356805bc9a2d40d6d1/system/programs/hyprland/binds.nix#L18)
                toggle =
                  program:
                  let
                    prog = builtins.substring 0 14 program;
                  in
                  "pkill ${prog} || uwsm app -- ${program}";
                runOnce = program: "pgrep ${program} || uwsm app -- ${program}";
                yt-mpv = pkgs.writeShellApplication {
                  name = "yt";
                  runtimeInputs = [
                    pkgs.mpv
                    pkgs.wl-clipboard
                    pkgs.libnotify
                  ];
                  text = ''
                    URL=$(wl-paste)
                    notify-send "Opening video" "$URL"
                    mpv "$URL"
                  '';
                };
              in
              [
                "ALT_SHIFT, Q, killactive"
                # app keybinds
                "$mod, RETURN, exec, uwsm app -- ${terminal}"
                "SUPER, E, exec, foot -a foot-files -- fish -c yazi"
                "ALT_SHIFT, W, exec, uwsm app -- firefox"
                "ALT_SHIFT, D, exec, ${runOnce "discord"}"
                "ALT_SHIFT, S, exec, ${runOnce "steam"}"
                "ALT_SHIFT, Y, exec, ${lib.getExe yt-mpv}"
                "ALT_SHIFT, O, exec, uwsm app -- win"
                # focus keybinds
                (mvfocus "h" "l")
                (mvfocus "j" "d")
                (mvfocus "k" "u")
                (mvfocus "l" "r")
                (mvwindow "h" "l")
                (mvwindow "j" "d")
                (mvwindow "k" "u")
                (mvwindow "l" "r")
                (resizeactive "h" "-80 0")
                (resizeactive "j" "0 80")
                (resizeactive "k" "0 -80")
                (resizeactive "l" "80 0")
                "$mod, p, pseudo"
                "$mod, s, layoutmsg, togglesplit"
                # pypr scratchpads
                "Control_L&Alt_L, K, exec, pypr toggle password"
                "Control_L&Alt_L, M, exec, pypr toggle music"
                "Control_L&Alt_L, G, exec, pypr toggle gpt"
                "Control_L&Alt_L, B, exec, pypr toggle bluetooth"
                "Control_L&Alt_L, P, exec, pypr toggle volume"
                # screenshot & picker
                "$mod, C, exec, ${lib.getExe pkgs.hyprpicker} | ${wl-copy}"
                "$mod, X, exec, ${lib.getExe pkgs.cliphist} list | anyrun --show-results-immediately true --plugins ${
                  inputs.anyrun.packages.${pkgs.stdenv.hostPlatform.system}.stdin
                }/lib/libstdin.so | ${lib.getExe pkgs.cliphist} decode | ${wl-copy}"
                ", Print, exec, ${lib.getExe grimblast} --notify --cursor copysave output"
                "ALT , Print, exec, ${lib.getExe screenshot-area}"
                "SHIFT , Print, exec, ${lib.getExe screenshot-area-ocr}"
                # "$mod, SPACE, exec, ${toggle "rofi"} -show combi"
                "$mod, SPACE, exec, ${toggle "anyrun"}"
                "$mod, ESCAPE, exec, ${lib.getExe pkgs.wlogout}"
                "$mod, V, togglefloating"
                "SUPER, F, fullscreen"
                "ALT, Tab, workspace, previous"
                # special workspace
                "$mod SHIFT, grave, movetoworkspace, special"
                "$mod, grave, togglespecialworkspace, DP-1"
                # move workspaces between monitors
                "$mod SHIFT ALT, bracketleft, movecurrentworkspacetomonitor, l"
                "$mod SHIFT ALT, bracketright, movecurrentworkspacetomonitor, r"
                # "Super, Tab, hyprexpo:expo,toggle"
                # "$mod, H, exec, pypr toggle helvum"
                #", swipe:3:ld, exec, pypr toggle music"
              ]
              ++ (
                # workspaces
                # binds $mod + [shift +] {1..10} to [move to] workspace {1..10}
                builtins.concatLists (
                  builtins.genList (
                    x:
                    let
                      ws =
                        let
                          c = (x + 1) / 10;
                        in
                        toString (x + 1 - (c * 10));
                    in
                    [
                      "$mod, ${ws}, workspace, ${toString (x + 1)}"
                      "$mod SHIFT, ${ws}, movetoworkspacesilent, ${toString (x + 1)}"
                    ]
                  ) 10
                )
              );
            bindm = [
              "$mod, mouse:272, movewindow"
              "$mod, mouse:273, resizewindow"
            ];
            bindl = [
              ", XF86AudioPlay, exec, ${playerctl} play-pause"
              ", XF86AudioNext, exec, ${playerctl} next"
              ", XF86AudioPrev, exec, ${playerctl} previous"
            ];
            bindel = [
              ", XF86AudioRaiseVolume, exec, ${swayosd-client} --output-volume raise"
              ", XF86AudioLowerVolume, exec, ${swayosd-client} --output-volume lower"
              ", XF86AudioMute, exec, ${swayosd-client} --output-volume mute-toggle"
              ", XF86MonBrightnessUp, exec, ${brightness} -A 5"
              ", XF86MonBrightnessDown, exec, ${brightness} -U 5"
            ];
          };
        };
      };
  };
}

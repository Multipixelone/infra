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
        ...
      }:
      let

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

        # Lua config helpers. Every setting renders as `hl.<name>(<args>)`, so a
        # bind is `_args = [ keys dispatcher flags? ]` and every dispatcher is a
        # raw Lua expression rather than a string.
        inherit (lib.generators) mkLuaInline;
        mod = "ALT";
        bind = keys: dispatcher: {
          _args = [
            keys
            dispatcher
          ];
        };
        bindFlags = flags: keys: dispatcher: {
          _args = [
            keys
            dispatcher
            flags
          ];
        };
        # bindm / bindl / bindel are now plain flag tables.
        bindm = bindFlags { mouse = true; };
        bindl = bindFlags { locked = true; };
        bindel = bindFlags {
          locked = true;
          repeating = true;
        };
        exec = cmd: mkLuaInline "hl.dsp.exec_cmd(${builtins.toJSON cmd})";
      in
      {
        wayland.windowManager.hyprland = {
          submaps.passthrough.settings.bind = [
            (bind "escape" (mkLuaInline ''hl.dsp.submap("reset")''))
          ];
          settings = {
            gesture = [
              {
                fingers = 3;
                direction = "horizontal";
                action = "workspace";
              }
            ];
            bind =
              let
                # this cool setup stolen from Aylur (https://github.com/Aylur/dotfiles/blob/7c4d6a708d426cb1a35a0f1776c4edc52ae1841c/home-manager/hyprland.nix)
                mvfocus = key: dir: bind "${mod} + ${key}" (mkLuaInline ''hl.dsp.focus({ direction = "${dir}" })'');
                mvwindow =
                  key: dir:
                  bind "${mod} + SHIFT + ${key}" (mkLuaInline ''hl.dsp.window.move({ direction = "${dir}" })'');
                resizeactive =
                  key: x: y:
                  bind "${mod} + SUPER + ${key}" (
                    mkLuaInline "hl.dsp.window.resize({ x = ${toString x}, y = ${toString y}, relative = true })"
                  );
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
                (bind "${mod} + SHIFT + Q" (mkLuaInline "hl.dsp.window.close()"))
                # app keybinds
                (bind "${mod} + RETURN" (exec "uwsm app -- foot"))
                (bind "SUPER + E" (exec "foot -a foot-files -- fish -c yazi"))
                (bind "${mod} + SHIFT + W" (exec "uwsm app -- firefox"))
                (bind "${mod} + SHIFT + D" (exec (runOnce "discord")))
                (bind "${mod} + SHIFT + S" (exec (runOnce "steam")))
                (bind "${mod} + SHIFT + Y" (exec (lib.getExe yt-mpv)))
                (bind "${mod} + SHIFT + O" (exec "uwsm app -- win"))
                # focus keybinds
                (mvfocus "h" "l")
                (mvfocus "j" "d")
                (mvfocus "k" "u")
                (mvfocus "l" "r")
                (mvwindow "h" "l")
                (mvwindow "j" "d")
                (mvwindow "k" "u")
                (mvwindow "l" "r")
                (resizeactive "h" (-80) 0)
                (resizeactive "j" 0 80)
                (resizeactive "k" 0 (-80))
                (resizeactive "l" 80 0)
                (bind "${mod} + p" (mkLuaInline "hl.dsp.window.pseudo()"))
                (bind "${mod} + s" (mkLuaInline ''hl.dsp.layout("togglesplit")''))
                # pypr scratchpads
                (bind "CTRL + ALT + K" (exec "pypr toggle password"))
                (bind "CTRL + ALT + M" (exec "pypr toggle music"))
                (bind "CTRL + ALT + G" (exec "pypr toggle gpt"))
                (bind "CTRL + ALT + B" (exec "pypr toggle bluetooth"))
                (bind "CTRL + ALT + P" (exec "pypr toggle volume"))
                # screenshot & picker
                (bind "${mod} + C" (exec "${lib.getExe pkgs.hyprpicker} | ${wl-copy}"))
                (bind "${mod} + X" (
                  exec "${lib.getExe pkgs.cliphist} list | anyrun --show-results-immediately true --plugins ${
                    inputs.anyrun.packages.${pkgs.stdenv.hostPlatform.system}.stdin
                  }/lib/libstdin.so | ${lib.getExe pkgs.cliphist} decode | ${wl-copy}"
                ))
                (bind "Print" (exec "${lib.getExe grimblast} --notify --cursor copysave output"))
                (bind "ALT + Print" (exec (lib.getExe screenshot-area)))
                (bind "SHIFT + Print" (exec (lib.getExe screenshot-area-ocr)))
                # (bind "${mod} + SPACE" (exec "${toggle "rofi"} -show combi"))
                (bind "${mod} + SPACE" (exec (toggle "anyrun")))
                (bind "${mod} + ESCAPE" (exec (lib.getExe pkgs.wlogout)))
                (bind "${mod} + V" (mkLuaInline ''hl.dsp.window.float({ action = "toggle" })''))
                (bind "SUPER + F" (mkLuaInline "hl.dsp.window.fullscreen()"))
                (bind "ALT + Tab" (mkLuaInline ''hl.dsp.focus({ workspace = "previous" })''))
                # passthrough submap, defined in submaps.passthrough above
                (bind "${mod} + SHIFT + P" (mkLuaInline ''hl.dsp.submap("passthrough")''))
                # special workspace
                (bind "${mod} + SHIFT + grave" (mkLuaInline ''hl.dsp.window.move({ workspace = "special" })''))
                (bind "${mod} + grave" (mkLuaInline ''hl.dsp.workspace.toggle_special("DP-1")''))
                # gaming / streamed workspace. Named rather than numbered so it
                # sits outside the $mod+{1..10} range below and stray windows
                # can't drift onto it — it is what Sunshine moves onto the
                # headless SUNSHINE output, so anything parked here is shown to
                # the Moonlight client. See modules/link/gamestream.nix.
                (bind "${mod} + G" (mkLuaInline ''hl.dsp.focus({ workspace = "name:gaming" })''))
                (bind "${mod} + SHIFT + G" (
                  mkLuaInline ''hl.dsp.window.move({ workspace = "name:gaming", follow = false })''
                ))
                # move workspaces between monitors
                (bind "${mod} + SHIFT + ALT + bracketleft" (
                  mkLuaInline ''hl.dsp.workspace.move({ monitor = "l" })''
                ))
                (bind "${mod} + SHIFT + ALT + bracketright" (
                  mkLuaInline ''hl.dsp.workspace.move({ monitor = "r" })''
                ))
                # (bind "SUPER + Tab" (mkLuaInline ''hl.dsp.layout("hyprexpo:expo, toggle")''))
                # (bind "${mod} + H" (exec "pypr toggle helvum"))
              ]
              ++ (
                # workspaces
                # binds $mod + [shift +] {1..10} to [move to] workspace {1..10}
                builtins.concatLists (
                  builtins.genList (
                    x:
                    let
                      ws = toString (x + 1);
                      key =
                        let
                          c = (x + 1) / 10;
                        in
                        toString (x + 1 - (c * 10));
                    in
                    [
                      (bind "${mod} + ${key}" (mkLuaInline "hl.dsp.focus({ workspace = ${ws} })"))
                      (bind "${mod} + SHIFT + ${key}" (
                        mkLuaInline "hl.dsp.window.move({ workspace = ${ws}, follow = false })"
                      ))
                    ]
                  ) 10
                )
              )
              ++ [
                (bindm "${mod} + mouse:272" (mkLuaInline "hl.dsp.window.drag()"))
                (bindm "${mod} + mouse:273" (mkLuaInline "hl.dsp.window.resize()"))

                (bindl "XF86AudioPlay" (exec "${playerctl} play-pause"))
                (bindl "XF86AudioNext" (exec "${playerctl} next"))
                (bindl "XF86AudioPrev" (exec "${playerctl} previous"))

                (bindel "XF86AudioRaiseVolume" (exec "${swayosd-client} --output-volume raise"))
                (bindel "XF86AudioLowerVolume" (exec "${swayosd-client} --output-volume lower"))
                (bindel "XF86AudioMute" (exec "${swayosd-client} --output-volume mute-toggle"))
                (bindel "XF86MonBrightnessUp" (exec "${brightness} -A 5"))
                (bindel "XF86MonBrightnessDown" (exec "${brightness} -U 5"))
              ];
          };
        };
      };
  };
}

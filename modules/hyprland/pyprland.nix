{
  flake.modules.homeManager.gui =
    hmArgs@{
      lib,
      pkgs,
      ...
    }:
    {
      home.packages = with pkgs; [
        pyprland
      ];
      # TODO: split this out and figure out module system.
      xdg.configFile."pypr/config.toml".text = ''
        [pyprland]
        plugins = ["scratchpads", "toggle_dpms"]

        # [scratchpads.music]
        # animation = "fromLeft"
        # command = "uwsm app -- foot -a foot-music ncmpcpp"
        # class = "foot-music"
        # size = "40% 90%"
        # unfocus = "hide"
        # lazy = false

        [scratchpads.gpt]
        animation = "fromLeft"
        command = "uwsm app -- footclient -a foot-gpt tgpt -m"
        class = "foot-gpt"
        size = "40% 90%"
        unfocus = "hide"
        lazy = true

        [scratchpads.volume]
        animation = "fromRight"
        command = "uwsm app -- ${lib.getExe pkgs.pwvucontrol}"
        class = "com.saivert.pwvucontrol"
        size = "40% 90%"
        unfocus = "hide"
        lazy = true

        [scratchpads.bluetooth]
        animation = "fromRight"
        command = "uwsm app -- ${lib.getExe' pkgs.blueman "blueman-manager"}"
        class = ".blueman-manager-wrapped"
        size = "40% 90%"
        unfocus = "hide"
        lazy = true

        # [scratchpads.helvum]
        # animation = "fromRight"
        # command = "uwsm app -- helvum"
        # class = "org.pipewire.Helvum"
        # size = "40% 90%"
        # unfocus = "hide"
        # lazy = true

        [scratchpads.password]
        animation = "fromBottom"
        command = "uwsm app -- 1password"
        class = "1Password"
        size = "40% 30%"
        max_size = "2560px 100%"
        position = "1% 66%"
        lazy = false
      '';
      systemd.user.services.pyprland = {
        Unit = {
          Description = "Scratchpads & many goodies for Hyprland";
          Documentation = "https://github.com/hyprland-community/pyprland";
          PartOf = [ "graphical-session.target" ];
          After = [ "graphical-session.target" ];
          ConditionEnvironment = "WAYLAND_DISPLAY";
          X-Reload-Triggers = [ "${hmArgs.config.xdg.configFile."pypr/config.toml".source}" ];
        };
        Install.WantedBy = [ "graphical-session.target" ];
        Service = with pkgs; {
          ExecCondition = ''${pkgs.systemd}/lib/systemd/systemd-xdg-autostart-condition "Hyprland" ""'';
          ExecStart = lib.getExe pyprland;
          ExecReload = "${lib.getExe pyprland} reload";
          ExecStop = "${lib.getExe pyprland} exit";
          ExecStopPost = pkgs.writeShellScript "pyprland-cleanup" ''
            rm -f ''${XDG_RUNTIME_DIR}/hypr/''${HYPRLAND_INSTANCE_SIGNATURE}/.pyprland.sock
          '';
          Restart = "on-failure";
          Nice = "19";
        };
      };
    };
}

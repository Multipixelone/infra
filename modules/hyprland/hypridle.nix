{ inputs, lib, ... }:
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
        timeout = 100;
        brillo = lib.getExe pkgs.brillo;
        hostname = if osConfig != null then osConfig.networking.hostName else null;
        hyprlandPkg =
          if osConfig != null then
            osConfig.programs.hyprland.package
          else
            inputs.hyprland.packages.${pkgs.stdenv.hostPlatform.system}.hyprland;
        hyprctl = lib.getExe' hyprlandPkg "hyprctl";
        suspend-script = pkgs.writeShellApplication {
          name = "suspend-script";
          runtimeInputs = [
            pkgs.playerctl
            pkgs.ripgrep
            pkgs.systemd
          ];
          text = ''
            # only suspend if audio isn't running & not plugged in
            playing() { playerctl -a status | rg Playing -q; }
            BAT_STATUS=/sys/class/power_supply/BAT0/status
            currentStatus=$(cat "$BAT_STATUS")

            if [ "$currentStatus" = "Discharging" ] && ! playing; then
              systemctl suspend-then-hibernate
            fi
          '';
        };
      in
      {
        systemd.user.services.hypridle.Unit.After = lib.mkForce "graphical-session.target";
        services.hypridle = {
          enable = lib.mkIf (hostname == "zelda") true;
          package = inputs.hypridle.packages.${pkgs.stdenv.hostPlatform.system}.hypridle;
          settings = {
            general = {
              lock_cmd = "pgrep hyprlock || ${lib.getExe config.programs.hyprlock.package}";
              before_sleep_cmd = lib.getExe' pkgs.systemd "loginctl" + " lock-session";
            };
            listener = [
              # {
              #   timeout = timeout - 40;
              #   on-timeout = "${brillo} -s dell::kbd_backlight -S 0";
              #   on-resume = "${brillo} -s dell::kbd_backlight -S 100";
              # }
              {
                timeout = timeout - 20;
                on-timeout = "${brillo} -O; ${brillo} -u 1000000 -S 5.00";
                on-resume = "${brillo} -I -u 500000";
              }
              {
                inherit timeout;
                on-timeout = "loginctl lock-session";
              }
              {
                timeout = timeout + 60;
                on-timeout = "${hyprctl} dispatch 'hl.dsp.dpms({ action = \"off\" })'";
                on-resume = "${hyprctl} dispatch 'hl.dsp.dpms({ action = \"on\" })'";
              }
              {
                timeout = timeout + 120;
                on-timeout = lib.getExe suspend-script;
              }
            ];
          };
        };
      };
  };
}

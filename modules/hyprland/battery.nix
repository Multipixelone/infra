{ withSystem, ... }:
{
  flake.modules = {
    homeManager.laptop =
      {
        osConfig,
        pkgs,
        lib,
        ...
      }:
      let
        hyprctl-instance = withSystem pkgs.stdenv.hostPlatform.system (
          psArgs: psArgs.config.packages.hyprctl-instance
        );
        script = pkgs.writeShellApplication {
          name = "watch-battery";
          runtimeInputs = with pkgs; [
            coreutils
            hyprctl-instance
            inotify-tools
            osConfig.programs.hyprland.package
          ];
          text = ''
            BAT=$(echo /sys/class/power_supply/BAT*)
            BAT_STATUS="$BAT/status"
            BAT_CAP="$BAT/capacity"
            HYPRLAND_INSTANCE_SIGNATURE=$(hyprctl-instance)
            export HYPRLAND_INSTANCE_SIGNATURE

            hypr() {
              local status=$1
              hyprctl --batch "keyword decoration:blur:enabled $status; keyword decoration:shadow:enabled $status"
            }

            # start the monitor loop
            currentStatus=$(cat "$BAT_STATUS")
            prevStatus=Charging

            # initial run
            if [ "$currentStatus" = "Discharging" ]; then
              hypr false
            else
              hypr true
            fi

            prevStatus="$currentStatus"

            # event loop
            while true; do
              currentStatus=$(cat "$BAT_STATUS")
              if [ "$currentStatus" != "$prevStatus" ]; then
              	# read the current state
              	if [ "$currentStatus" = "Discharging" ]; then
                  hypr false
              	else
                  hypr true
              	fi
                prevStatus="$currentStatus"
              fi

            	# wait for the next power change event
            	inotifywait -qq "$BAT_STATUS" "$BAT_CAP"
            done
          '';
        };
      in
      {
        home.packages = [
          script
        ];
        systemd.user.services.power-monitor = {
          Unit = {
            Description = "Hypr Power Monitor";
            PartOf = [ "graphical-session.target" ];
          };

          Service = {
            Type = "simple";
            ExecStart = lib.getExe script;
            Restart = "on-failure";
          };

          Install.WantedBy = [ "graphical-session.target" ];
        };
      };
  };
}

{ lib, ... }:
let
  deadmanScript =
    pkgs:
    pkgs.writeShellApplication {
      name = "openclaw-deadman";
      runtimeInputs = with pkgs; [
        curl
        coreutils
        gnugrep
        systemd
        jq
        gawk
      ];
      text = builtins.readFile ./scripts/deadman.sh;
    };
in
{
  configurations.nixos.link.module = { config, pkgs, ... }: {
    # A lingering user timer, independent of the gateway and the monitored
    # system units. Optional credentials allow checks and journaling even when
    # the same missing secret prevents Alertmanager startup.
    home-manager.users.tunnel.systemd.user = {
      services.openclaw-deadman = {
        Unit.Description = "Dead-man checks for OpenClaw and the alerting pipeline";
        Service = {
          Type = "oneshot";
          ExecStart = "${deadmanScript pkgs}/bin/openclaw-deadman";
          EnvironmentFile = "-${config.age.secrets."telegram-deadman".path}";
          StateDirectory = "openclaw-deadman";
          UMask = "0077";
        };
      };
      timers.openclaw-deadman = {
        Unit.Description = "Periodic independent gateway and alerting checks";
        Timer = {
          OnBootSec = "2min";
          OnUnitActiveSec = "2min";
          Unit = "openclaw-deadman.service";
        };
        Install.WantedBy = [ "timers.target" ];
      };
    };
  };

  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.alerting-deadman =
        pkgs.runCommand "alerting-deadman-check"
          {
            # Building the actual application runs writeShellApplication's shellcheck.
            nativeBuildInputs = [
              (deadmanScript pkgs)
              pkgs.python3
              pkgs.bash
              pkgs.curl
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.jq
              pkgs.gawk
            ];
          }
          ''
            python3 ${./fixtures/check-deadman.py} ${./scripts/deadman.sh}
            touch "$out"
          '';
    };
}

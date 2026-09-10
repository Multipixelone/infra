# https://github.com/fufexan/dotfiles/blob/483680e121b73db8ed24173ac9adbcc718cbbc6e/system/programs/gamemode.nix
{
  lib,
  withSystem,
  inputs,
  config,
  ...
}:
let
  username = config.flake.meta.owner.username;
in
{
  configurations.nixos.link.module =
    {
      pkgs,
      config,
      ...
    }:
    let
      hyprctl-instance = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.hyprctl-instance
      );
      programs = [
        hyprctl-instance
        config.programs.hyprland.package
        pkgs.systemd
        pkgs.gawk
        pkgs.coreutils
        pkgs.curl
        pkgs.libnotify
        pkgs.mako
      ];
      startscript = pkgs.writeShellApplication {
        name = "gamemode-start";
        runtimeInputs = programs;
        text = ''
          SECRET=$(cat "${config.age.secrets."syncthing".path}")
          HYPRLAND_INSTANCE_SIGNATURE=$(hyprctl-instance)
          systemctl stop podman-nicotine
          # The hook reduces the time between GameMode changing state and the
          # metric refresh; the timer remains authoritative.
          systemctl --no-block start gamemode-excusal-metrics.service
          # Fence CI onto two cores rather than stopping it: a stop fails the
          # running job outright, and a freeze would burn through the runner's
          # own job timeout. A fenced build crawls but still finishes.
          systemctl start forgejo-ci-throttle
          export HYPRLAND_INSTANCE_SIGNATURE
          # ledfx change scene (disabled temporarily)
          # curl -X 'PUT' 'http://link.bun-hexatonic.ts.net:8888/api/scenes' -H 'Content-Type: application/json' -d '{"id": "gaming-mode", "action": "activate"}'
          # send request to pause syncthing while game is playing
          curl -X POST -H "X-API-Key: $SECRET" http://localhost:8384/rest/system/pause
          hyprctl --batch 'keyword animations:enabled 0; keyword decoration:drop_shadow 0; keyword general:gaps_in 0; keyword general:gaps_out 0; keyword general:border_size 1; keyword decoration:rounding 0'
          notify-send -a 'Gamemode' 'Optimizations activated'
          makoctl mode -a dnd
        '';
      };
      endscript = pkgs.writeShellApplication {
        name = "gamemode-end";
        runtimeInputs = programs;
        text = ''
          SECRET=$(cat "${config.age.secrets."syncthing".path}")
          HYPRLAND_INSTANCE_SIGNATURE=$(hyprctl-instance)
          export HYPRLAND_INSTANCE_SIGNATURE
          systemctl start podman-nicotine
          # See the matching start hook: only the privileged oneshot unit
          # writes the metric, and its timer repairs any missed hook.
          systemctl --no-block start gamemode-excusal-metrics.service
          systemctl start forgejo-ci-unthrottle
          curl -X POST -H "X-API-Key: $SECRET" http://localhost:8384/rest/system/resume
          # curl -X 'PUT' 'http://link.bun-hexatonic.ts.net:8888/api/scenes' -H 'Content-Type: application/json' -d '{"id": "main-purple", "action": "activate"}'
          hyprctl --batch 'keyword animations:enabled 1; keyword decoration:drop_shadow 1; keyword general:gaps_in 5; keyword general:gaps_out 5; keyword general:border_size 3; keyword decoration:rounding 6'
          makoctl mode -r dnd
          notify-send -a 'Gamemode' 'Optimizations deactivated'
        '';
      };
    in
    {
      age.secrets = {
        "syncthing" = {
          file = "${inputs.secrets}/media/syncthing.age";
          mode = "400";
          owner = "tunnel";
          group = "users";
        };
      };
      users.extraGroups.gamemode.members = [ username ];
      programs = {
        gamescope = {
          enable = true;
          package = pkgs.gamescope;
          # capSysNice = true;
          args = [
            "--rt"
            "--expose-wayland"
          ];
        };
        gamemode = {
          enable = true;
          enableRenice = true;
          settings = {
            general = {
              softrealtime = "auto";
              renice = 15;
              inhibit_screensaver = 0;
            };
            gpu = {
              apply_gpu_optimisations = "accept-responsibility";
              gpu_device = 1;
              amd_performance_level = "high";
            };
            custom = {
              start = lib.getExe startscript;
              end = lib.getExe endscript;
            };
          };
        };
      };
      security.wrappers = {
        gamemode = {
          owner = "root";
          group = "root";
          source = "${lib.getExe' pkgs.gamemode "gamemoderun"}";
          capabilities = "cap_sys_ptrace,cap_sys_nice+pie";
        };
      };
      systemd.tmpfiles.rules = [
        # Textfile metrics persist across a reboot. Remove both forms before
        # the first timer run so an old active value cannot excuse downtime.
        "r /var/lib/prometheus-node-exporter-text-files/gamemode-excusal.prom - - - -"
        "r /var/lib/prometheus-node-exporter-text-files/gamemode-excusal.prom.tmp - - - -"
      ];
      systemd.services.gamemode-excusal-metrics = {
        description = "Export whether GameMode excuses planned Nicotine+ downtime";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe (
            pkgs.writeShellApplication {
              name = "gamemode-excusal-metrics";
              runtimeInputs = [
                pkgs.coreutils
                pkgs.util-linux
              ];
              text = ''
                metrics_dir=/var/lib/prometheus-node-exporter-text-files
                metrics_tmp="$metrics_dir/gamemode-excusal.prom.tmp"
                metrics_out="$metrics_dir/gamemode-excusal.prom"
                user_runtime=/run/user/$(id -u ${lib.escapeShellArg username})

                gamemode_status() {
                  runuser -u ${lib.escapeShellArg username} -- env \
                    XDG_RUNTIME_DIR="$user_runtime" \
                    DBUS_SESSION_BUS_ADDRESS="unix:path=$user_runtime/bus" \
                    ${lib.getExe' pkgs.gamemode "gamemoded"} -s 2>/dev/null
                }

                # `gamemoded -s` reports both active and inactive statuses with a
                # successful exit code, so inspect its exact status output.
                # Invocation failures safely publish no excusal.
                active=0
                if status="$(gamemode_status)" \
                  && [ "$status" = "gamemode is active" ]; then
                  active=1
                fi

                {
                  echo '# HELP excusal_active Whether a planned-downtime excusal signal is active.'
                  echo '# TYPE excusal_active gauge'
                  echo "excusal_active{signal=\"gamemode\"} $active"
                } > "$metrics_tmp"
                chmod 0644 "$metrics_tmp"
                mv "$metrics_tmp" "$metrics_out"
              '';
            }
          );
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = "read-only";
          ProtectSystem = "strict";
          ReadWritePaths = [ "/var/lib/prometheus-node-exporter-text-files" ];
        };
      };
      systemd.timers.gamemode-excusal-metrics = {
        description = "Refresh the GameMode planned-downtime excusal metric";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30s";
          OnUnitActiveSec = "1m";
          AccuracySec = "1s";
          Unit = "gamemode-excusal-metrics.service";
        };
      };
      # GameMode hooks run as tunnel and may only ask systemd to start this
      # narrow metric writer; they cannot write the textfile directly.
      security.polkit = {
        enable = true;
        extraConfig = ''
          polkit.addRule(function(action, subject) {
              if (action.id == "org.freedesktop.systemd1.manage-units" && subject.user == "${username}") {
                  if (action.lookup("unit") == "gamemode-excusal-metrics.service") {
                      if (action.lookup("verb") == "start") {
                          return polkit.Result.YES;
                      }
                  }
              }
          });
        '';
      };
    };
}

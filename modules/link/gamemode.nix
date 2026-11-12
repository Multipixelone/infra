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
      ];
      noctaliaDnd = pkgs.writeShellApplication {
        name = "gamemode-noctalia-dnd";
        runtimeInputs = [
          config.home-manager.users.${username}.programs.noctalia.package
          config.programs.hyprland.package
          pkgs.coreutils
          pkgs.jq
          pkgs.util-linux
        ];
        text = ''
          warn() { echo "gamemode-noctalia-dnd: $*" >&2; exit 1; }
          umask 077
          export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
          # Refuse public, foreign or symlinked runtime/state directories.
          [ ! -L "$XDG_RUNTIME_DIR" ] && [ -d "$XDG_RUNTIME_DIR" ] \
            && [ -O "$XDG_RUNTIME_DIR" ] \
            && [ "$(stat -c %a "$XDG_RUNTIME_DIR")" = 700 ] \
            || warn 'no private user runtime directory; skipping DND'
          state_dir="$XDG_RUNTIME_DIR/gamemode-noctalia"
          if [ ! -e "$state_dir" ]; then
            mkdir -m 700 "$state_dir" || warn 'cannot create DND state directory'
          fi
          [ ! -L "$state_dir" ] && [ -d "$state_dir" ] && [ -O "$state_dir" ] \
            && [ "$(stat -c %a "$state_dir")" = 700 ] \
            || warn 'unsafe DND state directory'
          # Duplicate/concurrent hooks must never replace the original state.
          exec 9>"$state_dir/lock"
          flock -n 9 || warn 'another DND hook is running; skipping'
          state_file="$state_dir/prior"
          if [ -e "$state_file" ] || [ -L "$state_file" ]; then
            [ ! -L "$state_file" ] && [ -f "$state_file" ] && [ -O "$state_file" ] \
              && [ "$(stat -c %a "$state_file")" = 600 ] \
              || warn 'unsafe saved DND state; leaving it untouched'
            read -r prior display socket_id extra < "$state_file" \
              || warn 'unreadable saved DND state; leaving it untouched'
            [ -z "$extra" ] || warn 'invalid saved DND state'
          elif [ "$1" = end ]; then
            warn 'no saved DND state; nothing to restore'
          else
            display="''${WAYLAND_DISPLAY:-}"
            # Prefer an inherited display only when its Noctalia socket exists.
            # Otherwise use the compositor selected by the visual hook, not a
            # hardcoded wayland-1 (or a different user's/session's daemon).
            if [[ ! "$display" =~ ^[[:alnum:]_.-]+$ ]] \
              || [ ! -S "$XDG_RUNTIME_DIR/noctalia-$display.sock" ]; then
              display=$(timeout -k 0.1s 1s hyprctl instances -j | jq -er \
                --arg instance "''${HYPRLAND_INSTANCE_SIGNATURE:-}" '
                  (if $instance == "" then sort_by(.time) | last
                   else map(select(.instance == $instance)) | first end)
                  | .wl_socket | select(type == "string" and length > 0)
                ') || warn 'cannot identify the compositor display; skipping DND'
            fi
            prior=
            socket_id=
          fi
          [[ "$display" =~ ^[[:alnum:]_.-]+$ ]] || warn 'invalid display; skipping DND'
          socket="$XDG_RUNTIME_DIR/noctalia-$display.sock"
          [ -S "$socket" ] && [ -O "$socket" ] || warn 'Noctalia socket unavailable; keeping saved state'
          current_socket_id=$(stat -c '%d:%i' "$socket")
          export WAYLAND_DISPLAY="$display"
          if [ -e "$state_file" ]; then
            case "$prior" in on|off) ;; *) warn 'invalid saved DND value' ;; esac
            # Never apply stale state to a replacement daemon/session. Retain it
            # for inspection/retry; logout clears this user-runtime-only state.
            [ "$socket_id" = "$current_socket_id" ] || warn 'stale Noctalia socket; keeping saved state without changing DND'
          else
            prior=$(timeout -k 0.1s 1s noctalia msg notification-dnd-status) \
              || warn 'DND query failed; skipping DND'
            case "$prior" in on|off) ;; *) warn 'invalid DND query response; skipping DND' ;; esac
            # Commit the original BEFORE enabling: even a timeout/partial enable
            # or killed hook leaves enough information for the end hook to undo.
            tmp=$(mktemp "$state_dir/prior.XXXXXX") || warn 'cannot create DND state file'
            trap 'rm -f -- "$tmp"' EXIT
            if ! printf '%s %s %s\n' "$prior" "$display" "$current_socket_id" > "$tmp"; then
              warn 'cannot write original DND state'
            fi
            mv -T -- "$tmp" "$state_file" || warn 'cannot save original DND state'
          fi
          if [ "$1" = start ]; then
            timeout -k 0.1s 1s noctalia msg notification-dnd-set on \
              || warn 'DND enable failed; keeping original state for restoration'
          else
            timeout -k 0.1s 1s noctalia msg notification-dnd-set "$prior" \
              || warn 'DND restore failed; keeping saved state for retry'
            # Only successful restoration retires the original state.
            rm -- "$state_file" || warn 'restored DND but could not remove saved state'
          fi
        '';
      };
      hyprlandConfig =
        config.home-manager.users.${username}.wayland.windowManager.hyprland.settings.config;
      gamingVisuals = {
        animations.enabled = false;
        decoration = {
          shadow.enabled = false;
          rounding = 0;
        };
        general = {
          gaps_in = 0;
          gaps_out = 0;
          border_size = 1;
        };
      };
      # Restore only the overridden fields, using the actual Home Manager values.
      # Do not reload: Sunshine may have added a dynamic headless output.
      normalVisuals = {
        animations.enabled = hyprlandConfig.animations.enabled;
        decoration = {
          shadow.enabled = hyprlandConfig.decoration.shadow.enabled;
          rounding = hyprlandConfig.decoration.rounding;
        };
        general = {
          inherit (hyprlandConfig.general) gaps_in gaps_out border_size;
        };
      };
      visualCommand = settings: lib.escapeShellArg "hl.config(${lib.generators.toLua { } settings})";
      startscript = pkgs.writeShellApplication {
        name = "gamemode-start";
        runtimeInputs = programs;
        text = ''
          # Queue units without waiting for slow shutdown/startup jobs: GameMode
          # gives this hook only ten seconds. Each independent failure is reported.
          systemctl --no-block stop podman-nicotine \
            || echo 'gamemode-start: failed to queue Nicotine stop' >&2
          # The timer remains authoritative if the metric refresh is missed.
          systemctl --no-block start gamemode-excusal-metrics.service \
            || echo 'gamemode-start: failed to queue metric refresh' >&2
          # Fence CI onto two cores rather than stopping it: a stop fails the
          # running job outright, and a freeze burns its own job timeout.
          systemctl --no-block start forgejo-ci-throttle \
            || echo 'gamemode-start: failed to queue CI throttle' >&2

          if SECRET=$(cat "${config.age.secrets."syncthing".path}") && [ -n "$SECRET" ]; then
            curl -fsS --max-time 3 -o /dev/null -X POST -H "X-API-Key: $SECRET" \
              http://localhost:8384/rest/system/pause \
              || echo 'gamemode-start: Syncthing pause failed' >&2
          else
            echo 'gamemode-start: Syncthing credential unavailable; skipping pause' >&2
          fi

          if HYPRLAND_INSTANCE_SIGNATURE=$(timeout 1s hyprctl-instance) && [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
            export HYPRLAND_INSTANCE_SIGNATURE
            timeout 1s hyprctl eval ${visualCommand gamingVisuals} \
              || echo 'gamemode-start: Hyprland visual override failed' >&2
          else
            echo 'gamemode-start: Hyprland instance unavailable; skipping visual override' >&2
          fi
          timeout 1s notify-send -a 'Gamemode' 'Optimizations activated' \
            || echo 'gamemode-start: notification failed' >&2
          # DND is capped at 3.6s; bounded curl/visual/notification steps total
          # 9.6s including DND, before small overhead.
          timeout -k 0.1s 3.5s ${lib.getExe noctaliaDnd} start \
            || echo 'gamemode-start: Noctalia DND skipped or failed' >&2
        '';
      };
      endscript = pkgs.writeShellApplication {
        name = "gamemode-end";
        runtimeInputs = programs;
        text = ''
          # Queue essential cleanup FIRST, independently of each other and all
          # optional work. Jobs keep running after GameMode's ten-second timeout.
          systemctl --no-block start link-cpu-idle-policy.service \
            || echo 'gamemode-end: failed to queue EPP restore' >&2
          systemctl --no-block start forgejo-ci-unthrottle \
            || echo 'gamemode-end: failed to queue CI unthrottle' >&2
          systemctl --no-block start podman-nicotine \
            || echo 'gamemode-end: failed to queue Nicotine start' >&2
          # Only the privileged oneshot writes the metric; its timer repairs misses.
          systemctl --no-block start gamemode-excusal-metrics.service \
            || echo 'gamemode-end: failed to queue metric refresh' >&2

          if SECRET=$(cat "${config.age.secrets."syncthing".path}") && [ -n "$SECRET" ]; then
            curl -fsS --max-time 3 -o /dev/null -X POST -H "X-API-Key: $SECRET" \
              http://localhost:8384/rest/system/resume \
              || echo 'gamemode-end: Syncthing resume failed' >&2
          else
            echo 'gamemode-end: Syncthing credential unavailable; skipping resume' >&2
          fi

          if HYPRLAND_INSTANCE_SIGNATURE=$(timeout 1s hyprctl-instance) && [ -n "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
            export HYPRLAND_INSTANCE_SIGNATURE
            timeout 1s hyprctl eval ${visualCommand normalVisuals} \
              || echo 'gamemode-end: Hyprland visual restore failed' >&2
          else
            echo 'gamemode-end: Hyprland instance unavailable; skipping visual restore' >&2
          fi
          timeout -k 0.1s 2s ${lib.getExe noctaliaDnd} end \
            || echo 'gamemode-end: Noctalia DND restore skipped or failed' >&2
          timeout 1s notify-send -a 'Gamemode' 'Optimizations deactivated' \
            || echo 'gamemode-end: notification failed' >&2
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
          # For problematic nested apps (mpv/Moonlight), DISABLE_GAMESCOPE_WSI=1
          # bypasses the libplacebo/vkroots issue: gamescope#2261.
          enableWsi = true;
          package = pkgs.gamescope;
          # capSysNice stays disabled; --rt has no effect without it.
          args = [
            "--expose-wayland"
          ];
        };
        gamemode = {
          enable = true;
          enableRenice = true;
          settings = {
            general = {
              desiredgov = "performance";
              defaultgov = "powersave";
              igpu_power_threshold = -1;
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
      # GameMode hooks run as tunnel and may start only these narrow helpers;
      # they cannot write CPU policy controls or the metric textfile directly.
      security.polkit = {
        enable = true;
        extraConfig = ''
          polkit.addRule(function(action, subject) {
              if (action.id == "org.freedesktop.systemd1.manage-units" && subject.user == "${username}") {
                  if (action.lookup("unit") == "gamemode-excusal-metrics.service" || action.lookup("unit") == "link-cpu-idle-policy.service") {
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

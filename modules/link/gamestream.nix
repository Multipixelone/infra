{
  lib,
  withSystem,
  ...
}:
{
  configurations.nixos.link.module =
    { pkgs, config, ... }:
    let
      moondeck = withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.moondeck);
      hyprctl-instance = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.hyprctl-instance
      );
      sh = lib.getExe pkgs.bash;
      # Dedicated workspace for everything that gets streamed. Deliberately NAMED
      # rather than numbered: `$mod + <n>` only binds 1-10, so a numbered
      # workspace is one keystroke away and stray windows drift onto it — an
      # Obsidian window living on old workspace 7 was being dragged onto the
      # headless output and shown to the Moonlight client. A named workspace is
      # reachable only from the explicit `$mod + G` bind.
      #
      # Named workspaces get negative internal ids, so anything matching on them
      # must compare `.workspace.name`, never `.workspace.id`. Keep in sync with
      # the `workspace name:gaming silent` rules in
      # modules/hyprland/conf/windowrules.nix and the bind in conf/binds.nix.
      stream-ws = "gaming";
      # `dispatch exec [rules] cmd` is gone: dispatch now takes a lua
      # expression, and the bracketed rule prefix is exec_cmd's second argument.
      hypr-exec =
        cmd:
        "${lib.getExe' config.programs.hyprland.package "hyprctl"} dispatch "
        + "\"hl.dsp.exec_cmd('${cmd}', { workspace = 'name:${stream-ws}' })\"";
      steam = lib.getExe config.programs.steam.package + " --";
      # HDR re-enable: set `stream-monitor = "DP-1";` and reference it below in
      # place of the literal "SUNSHINE" headless output to capture the physical
      # HDR display directly.
      # pkgs-stable = inputs.nixpkgs-stable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      # moondeck = pkgs.qt6.callPackage ../../pkgs/moondeck/default.nix {
      #   inherit (pkgs-stable) qt6;
      #   inherit (pkgs-stable) procps;
      # };
      # icon download and crop functions
      mk-icon =
        { icon-name }:
        pkgs.runCommand "${icon-name}-scaled.png" { }
          "${pkgs.imagemagick}/bin/convert -density 1200 -resize 500x -background none ${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark/128x128/apps/${icon-name}.svg -gravity center -extent 600x800 $out";
      # download-image = {
      #   url,
      #   hash,
      # }: let
      #   image = pkgs.fetchurl {inherit url hash;};
      # in
      #   pkgs.runCommand "${lib.nameFromURL url "."}.png" {} ''${pkgs.imagemagick}/bin/convert ${image} -background none -gravity center -extent 600x800 $out'';
      # implementation from https://github.com/TophC7/dot.nix/blob/724e87bb986f4e722490b0b739b8cbf57f1d5fcc/home/global/common/gaming/gamescope.nix
      gamescope-env = ''
        # MangoHud's session-wide env vars (modules/gaming/mangohud.nix) hook
        # every Vulkan process, including gamescope's own internal compositor
        # device. That double-hook crashes gamescope at shutdown (SIGSEGV in
        # libMangoHud.so during gamescope's CVulkanDevice teardown). gamescope
        # ships its own --mangoapp overlay specifically to avoid this; unset
        # the global hook here and rely on --mangoapp (added in
        # gamescope-base-opts below) instead.
        set -e MANGOHUD
        set -e MANGOHUD_DLSYM
        # Gamescope enables its WSI layer for children by default. Preserve the
        # caller's DISABLE_GAMESCOPE_WSI=1 escape hatch for incompatible nested
        # apps (e.g. mpv/Moonlight with libplacebo, gamescope issue #2261).
        set -x AMD_VULKAN_ICD RADV
        set -x RADV_PERFTEST aco
        set -x SDL_VIDEODRIVER wayland
        set -x STEAM_FORCE_DESKTOPUI_SCALING 1
        set -x STEAM_GAMEPADUI 1
        set -x STEAM_GAMESCOPE_CLIENT 1
        set -x STEAM_GAMESCOPE_HDR_SUPPORTED 1
      '';
      gamescope-default-width = "3840";
      gamescope-default-height = "2160";
      gamescope-default-refresh = "240";
      gamescope-base-opts = [
        "--fade-out-duration"
        "200"
        "--xwayland-count"
        "2"
        "-f"
        "--expose-wayland"
        "--backend"
        "wayland"
        "--hdr-enabled"
        # HDR output depends on the host Hyprland monitor's HDR configuration;
        # the Wayland backend manages DXVK_HDR based on that output.
        "--hdr-sdr-content-nits"
        "203"
        "--immediate-flips"
        "--force-grab-cursor"
        "--hide-cursor-delay"
        "3000"
        "--mangoapp"
      ];
      gamescope-run = pkgs.writers.writeFishBin "gamescope-run" ''
        # Session Environment
        ${gamescope-env}

        # Define and parse arguments using fish's built-in argparse
        argparse -i 'x/extra-args=' -- $argv
        if test $status -ne 0
          exit 1
        end

        # The remaining arguments ($argv) are the command to be run
        if test (count $argv) -eq 0
          echo "Usage: gamescope-run [-x|--extra-args \"<options>\"] <command> [args...]"
          echo ""
          echo "Examples:"
          echo "  gamescope-run heroic"
          echo "  gamescope-run -x \"--fsr-upscaling-sharpness 5\" steam"
          echo "  GAMESCOPE_EXTRA_OPTS=\"--fsr\" gamescope-run steam (legacy)"
          exit 1
        end

        # Resolution: prefer Sunshine client env vars, fall back to defaults
        set -l gs_width ${gamescope-default-width}
        set -l gs_height ${gamescope-default-height}
        set -l gs_refresh ${gamescope-default-refresh}
        if set -q SUNSHINE_CLIENT_WIDTH
          set gs_width $SUNSHINE_CLIENT_WIDTH
        end
        if set -q SUNSHINE_CLIENT_HEIGHT
          set gs_height $SUNSHINE_CLIENT_HEIGHT
        end
        if set -q SUNSHINE_CLIENT_FPS
          set gs_refresh $SUNSHINE_CLIENT_FPS
        end

        # Combine base args with dynamic resolution
        set -l final_args ${lib.escapeShellArgs gamescope-base-opts} -w $gs_width -h $gs_height -r $gs_refresh

        # Add args from -x/--extra-args flag, splitting the string into a list
        if set -q _flag_extra_args
          set -a final_args (string split ' ' -- $_flag_extra_args)
        end

        # For legacy support, add args from GAMESCOPE_EXTRA_OPTS if it exists
        if set -q GAMESCOPE_EXTRA_OPTS
          set -a final_args (string split ' ' -- $GAMESCOPE_EXTRA_OPTS)
        end

        # Execute gamescope with the final arguments and the command
        exec ${lib.getExe config.programs.gamescope.package} $final_args -- $argv
      '';
      # Local to streaming: never trust the shared resolver's newest instance
      # until its runtime directory and IPC socket belong to this user.
      stream-session-shell = ''
        stream_ipc() {
          timeout --kill-after=0.2s 1s hyprctl "$@"
        }
        stream_instance_valid() {
          local signature=$1
          [[ "$signature" =~ ^[[:alnum:]_-]+$ ]] &&
            [[ -d "$XDG_RUNTIME_DIR" && -O "$XDG_RUNTIME_DIR" ]] &&
            [[ -S "$XDG_RUNTIME_DIR/hypr/$signature/.socket.sock" && -O "$XDG_RUNTIME_DIR/hypr/$signature/.socket.sock" ]] &&
            HYPRLAND_INSTANCE_SIGNATURE="$signature" timeout --kill-after=0.2s 0.5s hyprctl monitors -j >/dev/null 2>&1
        }
        stream_resolve_instance() {
          local candidate
          XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
          export XDG_RUNTIME_DIR
          if stream_instance_valid "''${HYPRLAND_INSTANCE_SIGNATURE:-}"; then
            export HYPRLAND_INSTANCE_SIGNATURE
            return 0
          fi
          if candidate=$(timeout --kill-after=0.2s 0.5s hyprctl-instance) && stream_instance_valid "$candidate"; then
            HYPRLAND_INSTANCE_SIGNATURE=$candidate
            export HYPRLAND_INSTANCE_SIGNATURE
            return 0
          fi
          echo "No live Hyprland instance with a current-user IPC socket found" >&2
          return 1
        }
      '';
      # Both prep and the detached launcher use the same Sunshine defaults and
      # validation. Only digit/decimal strings reach shell/Lua command assembly.
      stream-mode-shell = ''
        width=''${1:-''${SUNSHINE_CLIENT_WIDTH:-3840}}
        height=''${2:-''${SUNSHINE_CLIENT_HEIGHT:-2160}}
        refresh_rate=''${3:-''${SUNSHINE_CLIENT_FPS:-60}}
        if [[ ! "$width" =~ ^[0-9]+$ || ! "$height" =~ ^[0-9]+$ || ! "$refresh_rate" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
          echo "Invalid stream mode: ''${width}x''${height}@''${refresh_rate}" >&2
          exit 1
        fi
        # Strip leading zeroes so every numeric string is valid JSON as well as
        # safe Lua/shell input; keep fractional refresh rates intact.
        while [[ "$width" =~ ^0[0-9] ]]; do width=''${width#0}; done
        while [[ "$height" =~ ^0[0-9] ]]; do height=''${height#0}; done
        while [[ "$refresh_rate" =~ ^0[0-9] ]]; do refresh_rate=''${refresh_rate#0}; done
        if ! jq -en --argjson width "$width" --argjson height "$height" --argjson refresh "$refresh_rate" \
          '[$width, $height, $refresh] | all(. > 0 and (isinfinite | not))' >/dev/null; then
          echo "Stream dimensions and refresh rate must be positive finite numbers" >&2
          exit 1
        fi
      '';
      # Shared by explicit undo and failed-prep EXIT rollback. Preserve the
      # selected instance: do not clean up a different compositor after a restart.
      stream-teardown-shell = ''
        stream_teardown() {
          if ! stream_instance_valid "''${HYPRLAND_INSTANCE_SIGNATURE:-}"; then
            echo "Skipping SUNSHINE teardown: selected compositor is gone" >&2
            return 0
          fi
          # Each IPC is bounded independently; a failed workspace move must not
          # prevent output removal. Never remove a physical output.
          stream_ipc dispatch 'hl.dsp.workspace.move({ workspace = "name:${stream-ws}", monitor = "DP-1" })' ||
            echo "Warning: could not park the gaming workspace on DP-1" >&2
          stream_ipc output remove SUNSHINE ||
            echo "Warning: could not remove SUNSHINE (it may already be absent)" >&2
        }
      '';
      # monitor prep command
      prep =
        let
          packages = [
            hyprctl-instance
            pkgs.gawk
            pkgs.coreutils
            pkgs.procps
            pkgs.curl
            pkgs.jq
            config.programs.hyprland.package
          ];
          do-command = pkgs.writeShellApplication {
            name = "do-command";
            runtimeInputs = packages;

            text = ''
              ${stream-session-shell}
              ${stream-mode-shell}
              ${stream-teardown-shell}
              stream_resolve_instance || exit 1
              # Sunshine does not run this prep's undo when prep itself fails.
              # Arm rollback before creating OR adopting a stale SUNSHINE output.
              stream_prep_exit() {
                local status=$?
                trap - EXIT
                if (( status != 0 )); then
                  stream_teardown || echo "Warning: SUNSHINE rollback failed" >&2
                fi
                exit "$status"
              }
              trap stream_prep_exit EXIT
              # HDR re-enable: add `cm = "hdr"` to the `hl.monitor` table below.
              # Currently SDR — committing an HDR/color-managed
              # virtual output segfaults Hyprland 0.55's aquamarine backend
              # (CHeadlessOutput::commit), which crashed the whole session and
              # made Sunshine app launches fail.
              # Unlock PC (so I don't have to type password on Steam Deck)
              # pkill -USR1 hyprlock || true

              # Idempotent: if a previous session's undo-cmd never ran (client
              # dropped, Hyprland restarted), SUNSHINE already exists and a second
              # create would either fail or spawn a differently-named output that
              # output_name would then never match.
              if ! stream_ipc monitors all -j | jq -e '.[] | select(.name == "SUNSHINE")' >/dev/null; then
                stream_ipc output create headless SUNSHINE
              fi

              # Bound the polling phase (~10s plus an in-flight bounded IPC).
              deadline=$((SECONDS + 10))
              while ! stream_ipc monitors all -j 2>/dev/null | jq -e '.[] | select(.name == "SUNSHINE")' >/dev/null; do
                if (( SECONDS >= deadline )); then
                  echo "Timed out waiting for SUNSHINE output to appear" >&2
                  exit 1
                fi
                sleep 0.5
              done

              # `hyprctl keyword` only targets the legacy config provider. This
              # setup uses the Lua provider, whose runtime API is `eval` plus the
              # same `hl.monitor` table used by the declarative config.
              stream_ipc eval "hl.monitor({
                output = \"SUNSHINE\",
                mode = \"''${width}x''${height}@''${refresh_rate}\",
                position = \"0x1920\",
                scale = 1,
              })"

              # Monitor application is asynchronous. Do not let Sunshine start
              # against the headless output's default 2x scale (which presents a
              # 1920x1080 mode as a 960x540 logical desktop).
              deadline=$((SECONDS + 5))
              while ! stream_ipc monitors all -j 2>/dev/null | jq -e \
                --argjson width "$width" \
                --argjson height "$height" \
                --argjson refresh "$refresh_rate" \
                '.[] | select(.name == "SUNSHINE" and .width == $width and .height == $height and .scale == 1
                  and (.refreshRate | type) == "number" and ((.refreshRate - $refresh) | fabs) < 0.5)' \
                >/dev/null; do
                if (( SECONDS >= deadline )); then
                  echo "Timed out applying SUNSHINE mode ''${width}x''${height}@''${refresh_rate} at scale 1" >&2
                  stream_ipc monitors all >&2 || true
                  exit 1
                fi
                sleep 0.25
              done

              stream_ipc dispatch 'hl.dsp.workspace.move({ workspace = "name:${stream-ws}", monitor = "SUNSHINE" })'
              stream_ipc dispatch 'hl.dsp.focus({ workspace = "name:${stream-ws}" })'
              trap - EXIT
            '';
          };
          undo-command = pkgs.writeShellApplication {
            name = "undo-command";
            runtimeInputs = packages;

            text = ''
              ${stream-session-shell}
              ${stream-teardown-shell}
              # Missing/restarted compositor or absent SUNSHINE is harmless.
              stream_resolve_instance || exit 0
              stream_teardown
            '';
          };
        in
        {
          do = "${sh} -c \"${lib.getExe do-command}\"";
          undo = "${sh} -c \"${lib.getExe undo-command}\"";
        };
      steam-kill =
        let
          kill-script = pkgs.writeShellApplication {
            name = "steam-kill";
            runtimeInputs = [
              pkgs.procps
              pkgs.coreutils
            ];
            text = ''
              # Exact current-user matching must not kill this steam-kill wrapper
              # (or another user's Steam). No match is harmless under `set -e`.
              uid=$(id -u)
              pkill -x -u "$uid" steam || true

              # pkill only sends SIGTERM; Steam takes seconds to actually exit.
              # Without this wait, reconnecting straight away launches a second
              # gamescope+Steam against the still-dying instance, which lands you
              # in "Steam is already running" contention and a black stream.
              for _ in $(seq 1 40); do
                pgrep -x -u "$uid" steam >/dev/null || break
                sleep 0.25
              done
              if pgrep -x -u "$uid" steam >/dev/null; then
                echo "Warning: Steam is still running after the 10s SIGTERM wait; reconnect may contend with it" >&2
              fi
            '';
          };
        in
        {
          do = "";
          undo = "${sh} -c \"${lib.getExe kill-script}\"";
        };
      # Self-contained launcher for the gamescope Big Picture app.
      # Retain a one-shot fullscreen fallback for gamescope when neither its
      # own -f nor the compositor's window rule has taken effect after mapping.
      # This checks actual state instead of assuming a particular Hyprland
      # version's rule behavior. Polls, fixes, exits — no socket listener.
      # Idempotent: only acts when fs == 0, so it becomes a no-op the moment the
      # window rule starts working again.
      bigpicture-launch =
        let
          steam-gamescope = "${lib.getExe gamescope-run} -x -e ${lib.getExe config.programs.steam.package} -steamos3 -steampal -steamdeck -gamepadui";
        in
        pkgs.writeShellApplication {
          name = "bigpicture-launch";
          runtimeInputs = [
            hyprctl-instance
            pkgs.jq
            pkgs.coreutils
            config.programs.hyprland.package
          ];
          text = ''
            ${stream-session-shell}
            ${stream-mode-shell}
            stream_resolve_instance || exit 1

            # exec_cmd inherits the compositor's environment, not Sunshine's.
            # Forward only validated numeric client mode fields (including the
            # intentional 3840x2160@60 fallback), never arbitrary environment.
            stream_ipc dispatch "hl.dsp.exec_cmd(\"${pkgs.coreutils}/bin/env SUNSHINE_CLIENT_WIDTH=$width SUNSHINE_CLIENT_HEIGHT=$height SUNSHINE_CLIENT_FPS=$refresh_rate ${steam-gamescope}\", { workspace = \"name:${stream-ws}\" })"

            # Detach the poll. Sunshine only treats a launcher that exits as a
            # detached command if it exits within 5s ("App exited gracefully
            # within 5 seconds of launch."); gamescope's window takes ~12s to
            # map, so polling in the foreground made Sunshine read the app as
            # finished, end the session, and fire the steam-kill undo cmd —
            # killing Steam mid-startup before it ever drew a frame.
            (
              deadline=$((SECONDS + 20))
              while (( SECONDS < deadline )); do
                # Scope the match to the stream workspace. A bare class match can
                # pick up a gamescope window stranded by a previous session and
                # fullscreen that instead of ours. Matched on `.workspace.name`
                # because named workspaces have negative, unstable ids.
                addr=$(stream_ipc -j clients \
                  | jq -r --arg ws ${stream-ws} 'first(.[] | select(.class == "gamescope" and .workspace.name == $ws)) // empty | .address') || { sleep 0.25; continue; }
                [[ "$addr" =~ ^0x[[:xdigit:]]+$ ]] || { sleep 0.25; continue; }

                # gamescope also fullscreens itself via -f. Let that land first so
                # we only act if it genuinely did not take.
                sleep 0.5
                fs=$(stream_ipc -j clients \
                  | jq -r --arg a "$addr" 'first(.[] | select(.address == $a)) // empty | .fullscreen') || continue

                if [ "$fs" = "0" ]; then
                  # Target the mapped window directly without stealing focus;
                  # explicit internal state is idempotent and client=-1 leaves
                  # the client's own fullscreen state alone (Hyprland 0.57 API).
                  stream_ipc dispatch "hl.dsp.window.fullscreen_state({ window = \"address:$addr\", internal = 2, client = -1 })" ||
                    echo "Warning: could not fullscreen the stream gamescope window" >&2
                fi
                break
              done
            ) &
          '';
        };
    in
    {
      environment.systemPackages = [
        gamescope-run
      ];
      # allow emulating ds5 controller
      boot.kernelModules = [ "uhid" ];
      # These MUST land before systemd's 73-seat-late.rules, which is what
      # actually runs the `uaccess` builtin that grants the seat user an ACL
      # (73-seat-late.rules:16 — `TAG=="uaccess" ... RUN{builtin}+="uaccess"`).
      # `services.udev.extraRules` writes to 99-local.rules, i.e. *after* 73, so
      # the tag was recorded and then silently never acted on: /dev/uhid stayed
      # 0600 root:root and the DS5 pad was dead in every single session
      # ("Gamepad ds5 is disabled due to Permission denied"). /dev/uinput
      # appeared to work only because Steam's own 60-steam-input.rules tags it
      # independently at priority 60. Shipping these as a package puts them at
      # 70, before the uaccess pass.
      services.udev.packages = [
        (pkgs.writeTextFile {
          name = "sunshine-input-udev-rules";
          destination = "/lib/udev/rules.d/70-sunshine-input.rules";
          text = ''
            KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"

            # Allows Sunshine to access /dev/uhid
            KERNEL=="uhid", TAG+="uaccess"

            # Joypads. Match keys are comma-separated; the PS5 line previously
            # separated KERNEL/ATTRS/MODE with bare spaces.
            KERNEL=="hidraw*", ATTRS{name}=="Sunshine PS5 (virtual) pad", MODE="0660", TAG+="uaccess"
            SUBSYSTEMS=="input", ATTRS{name}=="Sunshine X-Box One (virtual) pad", MODE="0660", TAG+="uaccess"
            SUBSYSTEMS=="input", ATTRS{name}=="Sunshine gamepad (virtual) motion sensors", MODE="0660", TAG+="uaccess"
            SUBSYSTEMS=="input", ATTRS{name}=="Sunshine Nintendo (virtual) pad", MODE="0660", TAG+="uaccess"
          '';
        })
      ];
      # nixpkgs' sunshine module only exposes `capSysAdmin`, so CAP_SYS_NICE has
      # to be bolted onto the wrapper it already defines. Without it, every
      # capture init logs "EGL: context priority set to HIGH but CAP_SYS_NICE
      # capability is missing" and the encoder falls back to default GPU
      # priority — it then contends with the game for the GPU exactly when the
      # game is saturating it, which is felt as stream stutter under load.
      # (Worth an upstream option: `capSysNice`, or folding it into capSysAdmin.)
      security.wrappers.sunshine.capabilities = lib.mkForce "cap_sys_admin,cap_sys_nice+p";

      # nixpkgs' sunshine module still sets the obsolete avahi.publish options,
      # whose warnings abort evaluation under abort-on-warn. Null them and set
      # the equivalent settings directly until the module is migrated.
      services.avahi = {
        publish = {
          enable = lib.mkForce null;
          userServices = lib.mkForce null;
        };
        settings.publish = {
          disable-publishing = false;
          disable-user-service-publishing = false;
          publish-addresses = true;
        };
      };

      services.sunshine = {
        enable = true;
        package = pkgs.sunshine.override {
          boost = pkgs.boost187;
        };
        capSysAdmin = true;
        openFirewall = true;
        settings = {
          channels = 2;
          # HDR re-enable: target physical DP-1 instead of the headless SUNSHINE
          # output by setting `output_name = "DP-1";` and `capture = "kms";` (KMS
          # is required to capture HDR metadata; wlr loses it).
          #
          # MUST be the output NAME, not an index. Selection happens in
          # video.cpp's refresh_displays(), which matches this string against the
          # display-name list; on a miss it silently leaves the index at 0 and
          # streams the first output. wlgrab itself does have a numeric-index
          # fallback, but it never sees this value — it is handed an
          # already-resolved name — so an index here can never reach it. A number
          # therefore streams DP-1 (your desktop) while the game launches unseen
          # on the headless output: you hear Steam, but the client shows the
          # desktop, with no warning logged anywhere.
          output_name = "SUNSHINE";
          gamepad = "ds5";
          capture = "wlr";
          # allow guide press with back button after 2000 milliseconds
          back_button_timeout = 2000;
          # decrease fec percentage because I am not dropping many packets
          fec_percentage = "12";
          av1_mode = "3";
          hevc_mode = "3";
        };
        applications = {
          env = {
            PATH = "$(PATH)";
          };
          apps = [
            {
              name = "Desktop";
              prep-cmd = [ prep ];
              image-path = mk-icon { icon-name = "cinnamon-virtual-keyboard"; };
            }
            {
              name = "Prism Launcher";
              prep-cmd = [ prep ];
              cmd = hypr-exec "prismlauncher";
              image-path = pkgs.runCommand "prismlauncher.png" { } ''
                ${pkgs.imagemagick}/bin/convert -density 1200 -resize 500x -background none ${pkgs.prismlauncher}/share/icons/hicolor/scalable/apps/org.prismlauncher.PrismLauncher.svg -gravity center -extent 600x800 $out
              '';
            }
            {
              name = "Steam (Big Picture Fallback)";
              cmd = hypr-exec "${steam} -gamepadui";
              prep-cmd = [
                prep
                steam-kill
              ];
              image-path = mk-icon { icon-name = "steamvr"; };
            }
            {
              name = "Steam (Regular UI)";
              cmd = hypr-exec "${steam}";
              prep-cmd = [
                prep
                steam-kill
              ];
              image-path = mk-icon { icon-name = "steam"; };
            }
            {
              name = "Steam (Big Picture)";
              # args poached from https://gitlab.com/evlaV/jupiter-PKGBUILD/-/blob/master/gamescope/steam-launcher?ref_type=heads
              # bigpicture-launch forwards the client mode and retains an
              # idempotent fullscreen fallback for the mapped gamescope window.
              cmd = lib.getExe bigpicture-launch;
              prep-cmd = [
                prep
                steam-kill
              ];
              image-path = mk-icon { icon-name = "steamlink"; };
            }
            {
              name = "MoonDeckStream";
              cmd = "${moondeck}/bin/MoonDeckStream";
              # cmd = "${self.packages.${pkgs.stdenv.hostPlatform.system}.moondeck}/bin/MoonDeckStream";
              prep-cmd = [ prep ];
              image-path = mk-icon { icon-name = "moonlight"; };
              # Sunshine's key is `auto-detach`; the old `auto-detatch` spelling
              # was silently ignored, so MoonDeckStream was still being treated as
              # detachable.
              auto-detach = false;
            }
          ];
        };
      };
    };
}

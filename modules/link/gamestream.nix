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
        set -x ENABLE_GAMESCOPE_WSI 1
        set -x ENABLE_HDR_WSI 1
        set -x DXVK_HDR 1
        # HDR re-enable: comment the next line out — DISABLE_HDR_WSI overrides
        # ENABLE_HDR_WSI above and forces gamescope into SDR.
        set -x DISABLE_HDR_WSI 1
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
        # HDR re-enable: add "--hdr-debug-force-output" before the nits flag and
        # bump nits from 203 → 600 to match the physical monitor's peak.
        "--hdr-sdr-content-nits"
        "203"
        "--rt"
        "--immediate-flips"
        "--force-grab-cursor"
        "--hide-cursor-delay"
        "3000"
        "--mangoapp"
      ];
      # exec ${config.security.wrappers.gamescope.program} $final_args -- $argv
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
              HYPRLAND_INSTANCE_SIGNATURE=$(hyprctl-instance)
              export HYPRLAND_INSTANCE_SIGNATURE
              width=''${1:-3840}
              height=''${2:-2160}
              refresh_rate=''${3:-60}
              # HDR re-enable: append ",cm,hdr" to enable color-managed HDR on the
              # headless output. Currently SDR — committing an HDR/color-managed
              # virtual output segfaults Hyprland 0.55's aquamarine backend
              # (CHeadlessOutput::commit), which crashed the whole session and
              # made Sunshine app launches fail.
              mon_string="SUNSHINE,''${width}x''${height}@''${refresh_rate},0x1920,1"
              # Unlock PC (so I don't have to type password on Steam Deck)
              # pkill -USR1 hyprlock || true

              # Idempotent: if a previous session's undo-cmd never ran (client
              # dropped, Hyprland restarted), SUNSHINE already exists and a second
              # create would either fail or spawn a differently-named output that
              # output_name would then never match.
              if ! hyprctl monitors all -j | jq -e '.[] | select(.name == "SUNSHINE")' >/dev/null; then
                hyprctl output create headless SUNSHINE
              fi

              # Wait for the headless output to appear (up to ~10s)
              timeout=20
              while ! hyprctl monitors all -j 2>/dev/null | jq -e '.[] | select(.name == "SUNSHINE")' >/dev/null; do
                if (( --timeout == 0 )); then
                  echo "Timed out waiting for SUNSHINE output to appear" >&2
                  exit 1
                fi
                sleep 0.5
              done

              hyprctl keyword monitor "$mon_string"
              sleep 1
              hyprctl dispatch 'hl.dsp.workspace.move({ workspace = "name:${stream-ws}", monitor = "SUNSHINE" })'
              hyprctl dispatch 'hl.dsp.focus({ workspace = "name:${stream-ws}" })'
            '';
          };
          undo-command = pkgs.writeShellApplication {
            name = "undo-command";
            runtimeInputs = packages;

            text = ''
              HYPRLAND_INSTANCE_SIGNATURE=$(hyprctl-instance)
              export HYPRLAND_INSTANCE_SIGNATURE
              # Tolerant teardown: this runs on every disconnect, including ones
              # where prep never completed. Leaving a stale SUNSHINE output behind
              # is the one state that breaks the *next* launch, so neither step
              # may abort the other under `set -e`.
              # Park the workspace on a real monitor by NAME. The old `0` was a
              # monitor id, which depends on connector assignment order.
              hyprctl dispatch 'hl.dsp.workspace.move({ workspace = "name:${stream-ws}", monitor = "DP-1" })' || true
              hyprctl output remove SUNSHINE || true
            '';
          };
        in
        {
          do = "${sh} -c \"${lib.getExe do-command} \${SUNSHINE_CLIENT_WIDTH} \${SUNSHINE_CLIENT_HEIGHT} \${SUNSHINE_CLIENT_FPS}\"";
          undo = "${sh} -c \"${lib.getExe undo-command}\"";
        };
      steam-kill =
        let
          kill-script = pkgs.writeShellApplication {
            name = "steam-kill";
            runtimeInputs = [ pkgs.procps ];
            text = ''
              # `|| true`: pkill exits 1 when nothing matched, which under `set -e`
              # aborts the script and makes Sunshine log "Return code [1]" on every
              # teardown where Steam was already gone.
              pkill steam || true

              # pkill only sends SIGTERM; Steam takes seconds to actually exit.
              # Without this wait, reconnecting straight away launches a second
              # gamescope+Steam against the still-dying instance, which lands you
              # in "Steam is already running" contention and a black stream.
              for _ in $(seq 1 40); do
                pgrep -x steam >/dev/null || break
                sleep 0.25
              done
            '';
          };
        in
        {
          do = "";
          undo = "${sh} -c \"${lib.getExe kill-script}\"";
        };
      # Self-contained launcher for the gamescope Big Picture app.
      # Hyprland 0.55 regressed the `fullscreen` window-rule effect: it is a
      # silent no-op for every window (the `fullscreen` dispatcher still works,
      # and `match:class ^(gamescope)$, fullscreen on` in windowrules.nix no
      # longer fires at open). Until the upstream fullscreen refactor lands
      # (hyprwm/Hyprland#14705), fullscreen the gamescope window ourselves once
      # it maps. One-shot: polls, fixes, exits — no persistent socket listener.
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
            HYPRLAND_INSTANCE_SIGNATURE=$(hyprctl-instance)
            export HYPRLAND_INSTANCE_SIGNATURE

            hyprctl dispatch 'hl.dsp.exec_cmd("${steam-gamescope}", { workspace = "name:${stream-ws}" })'

            # Detach the poll. Sunshine only treats a launcher that exits as a
            # detached command if it exits within 5s ("App exited gracefully
            # within 5 seconds of launch."); gamescope's window takes ~12s to
            # map, so polling in the foreground made Sunshine read the app as
            # finished, end the session, and fire the steam-kill undo cmd —
            # killing Steam mid-startup before it ever drew a frame.
            (
              for _ in $(seq 1 80); do
                # Scope the match to the stream workspace. A bare class match can
                # pick up a gamescope window stranded by a previous session and
                # fullscreen that instead of ours. Matched on `.workspace.name`
                # because named workspaces have negative, unstable ids.
                addr=$(hyprctl -j clients \
                  | jq -r --arg ws ${stream-ws} 'first(.[] | select(.class == "gamescope" and .workspace.name == $ws)) // empty | .address')
                [ -n "$addr" ] || { sleep 0.25; continue; }

                # gamescope also fullscreens itself via -f. Let that land first so
                # we only act if it genuinely did not take.
                sleep 0.5
                fs=$(hyprctl -j clients \
                  | jq -r --arg a "$addr" 'first(.[] | select(.address == $a)) // empty | .fullscreen')

                if [ "$fs" = "0" ]; then
                  # One IPC round-trip, and an explicit state rather than a
                  # toggle. `dispatch fullscreen` toggles whatever is focused, so
                  # the old focuswindow-then-fullscreen pair could fullscreen an
                  # unrelated window if focus moved in between, or toggle
                  # gamescope back *out* of fullscreen if it self-fullscreened in
                  # the gap. `fullscreenstate 2 -1` sets internal fullscreen and
                  # leaves the client state alone, so re-running is a no-op.
                  hyprctl --batch "dispatch hl.dsp.focus({ window = \"address:$addr\" }) ; dispatch hl.dsp.window.fullscreen_state({ internal = 2, client = -1 })"
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
              # bigpicture-launch wraps the gamescope launch and force-fullscreens
              # the gamescope window (Hyprland 0.55 `fullscreen` rule regression).
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

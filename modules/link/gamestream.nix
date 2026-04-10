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
      hypr-dispatch =
        lib.getExe' config.programs.hyprland.package "hyprctl" + " dispatch exec [workspace 7]";
      steam = lib.getExe config.programs.steam.package + " --";
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
        set -x ENABLE_GAMESCOPE_WSI 1
        set -x ENABLE_HDR_WSI 1
        set -x DXVK_HDR 1
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
        "--hdr-debug-force-output"
        "--hdr-sdr-content-nits"
        "600"
        "--rt"
        "--immediate-flips"
        "--force-grab-cursor"
        "--hide-cursor-delay"
        "3000"
      ];
      # exec ${config.security.wrappers.gamescope.program} $final_args -- $argv
      gamescope-run = pkgs.writeScriptBin "gamescope-run" ''
        #!${lib.getExe pkgs.fish}

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
              mon_string="SUNSHINE,''${width}x''${height}@''${refresh_rate},0x1920,1,cm,hdr"
              # Unlock PC (so I don't have to type password on Steam Deck)
              # pkill -USR1 hyprlock || true
              hyprctl output create headless SUNSHINE
              sleep 2
              hyprctl keyword monitor "$mon_string"
              sleep 2
              hyprctl dispatch moveworkspacetomonitor 7 SUNSHINE
              # wait before we switch to the new workspace
              sleep 2
              hyprctl dispatch workspace 7
            '';
          };
          undo-command = pkgs.writeShellApplication {
            name = "undo-command";
            runtimeInputs = packages;

            text = ''
              HYPRLAND_INSTANCE_SIGNATURE=$(hyprctl-instance)
              export HYPRLAND_INSTANCE_SIGNATURE
              hyprctl dispatch moveworkspacetomonitor 7 0
              hyprctl output remove SUNSHINE
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
              pkill steam
            '';
          };
        in
        {
          do = "";
          undo = "${sh} -c \"${lib.getExe kill-script}\"";
        };
    in
    {
      environment.systemPackages = [
        gamescope-run
      ];
      # allow emulating ds5 controller
      boot.kernelModules = [ "uhid" ];
      services.udev.extraRules = ''
        KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"

        # Allows Sunshine to access /dev/uhid
        KERNEL=="uhid", TAG+="uaccess"

        # Joypads
        KERNEL=="hidraw*" ATTRS{name}=="Sunshine PS5 (virtual) pad" MODE="0660", TAG+="uaccess"
        SUBSYSTEMS=="input", ATTRS{name}=="Sunshine X-Box One (virtual) pad", MODE="0660", TAG+="uaccess"
        SUBSYSTEMS=="input", ATTRS{name}=="Sunshine gamepad (virtual) motion sensors", MODE="0660", TAG+="uaccess"
        SUBSYSTEMS=="input", ATTRS{name}=="Sunshine Nintendo (virtual) pad", MODE="0660", TAG+="uaccess"
      '';
      services.sunshine = {
        enable = true;
        package = pkgs.sunshine.override {
          boost = pkgs.boost187;
        };
        capSysAdmin = true;
        openFirewall = true;
        settings = {
          channels = 2;
          output_name = 2;
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
              cmd = "${hypr-dispatch} \"prismlauncher\"";
              image-path = pkgs.runCommand "prismlauncher.png" { } ''
                ${pkgs.imagemagick}/bin/convert -density 1200 -resize 500x -background none ${pkgs.prismlauncher}/share/icons/hicolor/scalable/apps/org.prismlauncher.PrismLauncher.svg -gravity center -extent 600x800 $out
              '';
            }
            {
              name = "Steam (Big Picture Fallback)";
              cmd = "${hypr-dispatch} \"${steam} -gamepadui\"";
              prep-cmd = [
                prep
                steam-kill
              ];
              image-path = mk-icon { icon-name = "steamvr"; };
            }
            {
              name = "Steam (Regular UI)";
              cmd = "${hypr-dispatch} \"${steam}\"";
              prep-cmd = [
                prep
                steam-kill
              ];
              image-path = mk-icon { icon-name = "steam"; };
            }
            {
              name = "Steam (Big Picture)";
              cmd =
                let
                  # args poached from https://gitlab.com/evlaV/jupiter-PKGBUILD/-/blob/master/gamescope/steam-launcher?ref_type=heads
                  steam-gamescope = ''${lib.getExe gamescope-run} -x "-e" ${lib.getExe pkgs.steam} -steamos3 -steampal -steamdeck -gamepadui'';
                in
                ''${hypr-dispatch} "${steam-gamescope}"'';
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
              auto-detatch = false;
            }
          ];
        };
      };
    };
}

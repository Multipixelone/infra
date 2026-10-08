{
  lib,
  rootPath,
  withSystem,
  ...
}:
let
  calderaModule =
    {
      playerName,
      enable ? (_: true),
      requireSpeakerUnmute ? false,
    }:
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      enabled = enable config;
      caldera-headless = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.caldera-headless
      );
      stateDir = "/var/lib/caldera-headless";
      configDir = "${stateDir}/.config/caldera-music";
      audioReady = pkgs.writeShellScript "caldera-headless-wait-for-audio" ''
        set -eu

        deadline=$(${pkgs.coreutils}/bin/date +%s)
        deadline=$((deadline + 30))
        while ${lib.optionalString requireSpeakerUnmute "! ${pkgs.systemd}/bin/systemctl --system is-active --quiet marin-speaker-unmute.service || "}! ${pkgs.wireplumber}/bin/wpctl inspect @DEFAULT_AUDIO_SINK@ >/dev/null 2>&1; do
          if [ "$(${pkgs.coreutils}/bin/date +%s)" -ge "$deadline" ]; then
            echo "Caldera audio readiness timed out: ${lib.optionalString requireSpeakerUnmute "marin-speaker-unmute.service must be active and "}PipeWire must have a default audio sink." >&2
            exit 1
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
      '';
      # plex.tv registration runs once at startup and is never retried, so a
      # start during a resolver restart (e.g. blocky during a deploy) leaves the
      # player invisible to Plex clients. Wait briefly for DNS, but still start
      # without it so the player works when the internet is down.
      dnsReady = pkgs.writeShellScript "caldera-headless-wait-for-dns" ''
        set -eu

        deadline=$(${pkgs.coreutils}/bin/date +%s)
        deadline=$((deadline + 30))
        while ! ${pkgs.getent}/bin/getent hosts plex.tv >/dev/null 2>&1; do
          if [ "$(${pkgs.coreutils}/bin/date +%s)" -ge "$deadline" ]; then
            echo "Caldera DNS readiness timed out: starting without plex.tv registration." >&2
            exit 0
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done
      '';

      control = pkgs.writeShellApplication {
        name = "caldera-headless-control";
        runtimeInputs = [
          pkgs.systemd
          pkgs.util-linux
          caldera-headless
        ];
        text = ''
          set -euo pipefail

          case "''${1-}" in
            login)
              if [[ $# -ne 1 ]]; then
                echo "usage: caldera-headless-control login" >&2
                exit 64
              fi
              args=(--login --player-name ${lib.escapeShellArg playerName})
              ;;
            list-devices)
              if [[ $# -ne 1 ]]; then
                echo "usage: caldera-headless-control list-devices" >&2
                exit 64
              fi
              args=(--list-devices)
              ;;
            device)
              if [[ $# -ne 2 ]]; then
                echo "usage: caldera-headless-control device <device-uid>" >&2
                exit 64
              fi
              args=(--device "$2")
              ;;
            *)
              echo "usage: caldera-headless-control {login|list-devices|device <device-uid>}" >&2
              exit 64
              ;;
          esac

          # The daemon and control command take the same exclusive lock. Stop
          # first, then refuse rather than race if another operation acquired it.
          systemctl --user --machine=tunnel@.host stop caldera-headless.service
          exec systemd-run --user --machine=tunnel@.host --wait --collect --pty \
            --unit=caldera-headless-control \
            --property=Conflicts=caldera-headless.service \
            --property=UMask=0077 \
            --property=Environment=HOME=${stateDir} \
            --property=Environment=XDG_CONFIG_HOME=${configDir} \
            --property=Environment=XDG_CACHE_HOME=${stateDir}/.cache \
            -- ${pkgs.util-linux}/bin/flock --nonblock --exclusive "${stateDir}/.operation.lock" \
            ${lib.getExe caldera-headless} --config "${configDir}" "''${args[@]}"
        '';
      };
      login = pkgs.writeShellScriptBin "caldera-headless-login" ''
        exec ${lib.getExe control} login
      '';
      listDevices = pkgs.writeShellScriptBin "caldera-headless-list-devices" ''
        exec ${lib.getExe control} list-devices
      '';
      setDevice = pkgs.writeShellScriptBin "caldera-headless-set-device" ''
        exec ${lib.getExe control} device "$@"
      '';
    in
    lib.mkIf enabled {
      assertions = [
        {
          assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
          message = "Caldera headless is only packaged for x86_64-linux.";
        }
      ];

      # Caldera shares tunnel's user PipeWire manager and its default endpoint;
      # no dedicated Caldera account or group is needed.
      systemd.tmpfiles.rules = [
        "d ${stateDir} 0700 tunnel users - -"
      ];

      # Keep existing credentials private while migrating the old service's
      # tree. Only the state root's required mode is normalized; descendants
      # retain their existing modes. Stop the former system unit before removing
      # its account, so this completes before the user unit can use the tree.
      system.activationScripts.caldera-headless-state = {
        deps = [ "users" ];
        text = ''
          stateDir=${stateDir}
          ${pkgs.systemd}/bin/systemctl stop caldera-headless.service || true
          if [ -e "$stateDir" ] && [ ! -d "$stateDir" ]; then
            echo "caldera-headless state path is not a directory: $stateDir" >&2
            exit 1
          fi
          if [ ! -e "$stateDir" ]; then
            ${pkgs.coreutils}/bin/install -d -m 0700 -o tunnel -g users "$stateDir"
          fi
          ${pkgs.coreutils}/bin/chown tunnel:users "$stateDir"
          ${pkgs.coreutils}/bin/chmod 0700 "$stateDir"
          ${pkgs.findutils}/bin/find "$stateDir" -xdev -mindepth 1 -exec ${pkgs.coreutils}/bin/chown -h tunnel:users {} +
          if ${pkgs.coreutils}/bin/id -u caldera-headless >/dev/null 2>&1; then
            ${pkgs.shadow}/bin/userdel caldera-headless
          fi
          ${pkgs.shadow}/bin/groupdel caldera-headless || groupdelStatus=$?
          if [ "''${groupdelStatus:-0}" -ne 0 ] && [ "$groupdelStatus" -ne 6 ]; then
            exit "$groupdelStatus"
          fi
        '';
      };

      environment.systemPackages = [
        control
        login
        listDevices
        setDevice
      ];

      # Static inspection found the standard Plex Companion HTTP listener and
      # GDM discovery listener. Xita's default 9999 exposure is not enabled
      # here until live acceptance verifies its role on the host's interfaces.
      networking.firewall = {
        allowedTCPPorts = [ 32500 ];
        allowedUDPPorts = [ 32412 ];
      };

      systemd.user.services.caldera-headless = {
        description = "Caldera Music Headless";
        after = [
          "pipewire.service"
          "wireplumber.service"
        ];
        wants = [
          "pipewire.service"
          "wireplumber.service"
        ];
        wantedBy = [ "default.target" ];
        unitConfig = {
          ConditionUser = "tunnel";
          StartLimitIntervalSec = "0";
        };
        serviceConfig = {
          Type = "simple";
          UMask = "0077";
          Environment = [
            "HOME=${stateDir}"
            "XDG_CONFIG_HOME=${configDir}"
            "XDG_CACHE_HOME=${stateDir}/.cache"
          ];
          ExecStartPre = [
            audioReady
            dnsReady
          ];
          ExecStart = "${pkgs.util-linux}/bin/flock --exclusive ${stateDir}/.operation.lock ${lib.getExe caldera-headless} --config ${configDir}";
          Restart = "on-failure";
          RestartSec = "5s";

          # User services cannot safely use the mount-namespace hardening used
          # by the former system service. The state directory remains private.
          NoNewPrivileges = true;
        };
      };
    };
in
{
  nixpkgs.config.allowUnfreePackages = [ "caldera-headless" ];

  perSystem =
    { system, pkgs, ... }:
    {
      # Caldera publishes a native x86_64 ELF only. Keep the package absent,
      # rather than merely unavailable in metadata, on other evaluated systems.
      packages = lib.optionalAttrs (system == "x86_64-linux") {
        caldera-headless = pkgs.callPackage "${rootPath}/pkgs/caldera-headless" { };
      };
    };

  configurations.nixos.marin.module = calderaModule {
    playerName = "Marin";
    enable = config: config.services.marin.headlessPlayer == "caldera";
    requireSpeakerUnmute = true;
  };

  configurations.nixos.link.module = calderaModule {
    playerName = "Link";
  };
}

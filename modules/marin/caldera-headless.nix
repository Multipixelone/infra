{
  lib,
  rootPath,
  withSystem,
  ...
}:
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

  configurations.nixos.marin.module =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      enabled = config.services.marin.headlessPlayer == "caldera";
      caldera-headless = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.caldera-headless
      );
      stateDir = "/var/lib/caldera-headless";
      configDir = "${stateDir}/.config/caldera-music";

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
              args=(--login --player-name Marin)
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
                echo "usage: caldera-headless-control device <ALSA-device-uid>" >&2
                exit 64
              fi
              args=(--device "$2")
              ;;
            *)
              echo "usage: caldera-headless-control {login|list-devices|device <ALSA-device-uid>}" >&2
              exit 64
              ;;
          esac

          # The daemon and control command take the same exclusive lock. Stop
          # first, then refuse rather than race if another operation acquired it.
          systemctl stop caldera-headless.service
          exec systemd-run --wait --collect --pty \
            --unit=caldera-headless-control \
            --property=Conflicts=caldera-headless.service \
            --property=User=caldera-headless \
            --property=Group=caldera-headless \
            --property=SupplementaryGroups=audio \
            --property=StateDirectory=caldera-headless \
            --property=StateDirectoryMode=0700 \
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

      users.users.caldera-headless = {
        isSystemUser = true;
        group = "caldera-headless";
        extraGroups = [ "audio" ];
        home = stateDir;
        createHome = false;
      };
      users.groups.caldera-headless = { };

      environment.systemPackages = [
        control
        login
        listDevices
        setDevice
      ];

      # Static inspection found the standard Plex Companion HTTP listener and
      # GDM discovery listener. Xita's default 9999 exposure is not enabled
      # here until live acceptance verifies its role on Marin's interfaces.
      networking.firewall = {
        allowedTCPPorts = [ 32500 ];
        allowedUDPPorts = [ 32412 ];
      };

      systemd.services.caldera-headless = {
        description = "Caldera Music Headless";
        after = [
          "network-online.target"
          "marin-speaker-unmute.service"
        ];
        wants = [
          "network-online.target"
          "marin-speaker-unmute.service"
        ];
        wantedBy = [ "multi-user.target" ];
        unitConfig = {
          Conflicts = [ "plexamp-headless.service" ];
          StartLimitIntervalSec = "1min";
          StartLimitBurst = 3;
        };
        serviceConfig = {
          Type = "simple";
          User = "caldera-headless";
          Group = "caldera-headless";
          SupplementaryGroups = [ "audio" ];
          StateDirectory = "caldera-headless";
          StateDirectoryMode = "0700";
          UMask = "0077";
          Environment = [
            "HOME=${stateDir}"
            "XDG_CONFIG_HOME=${configDir}"
            "XDG_CACHE_HOME=${stateDir}/.cache"
          ];
          ExecStart = "${pkgs.util-linux}/bin/flock --exclusive ${stateDir}/.operation.lock ${lib.getExe caldera-headless} --config ${configDir}";
          Restart = "on-failure";
          RestartSec = "5s";

          # Do not use PrivateDevices: Caldera needs ALSA devices. Network
          # access is required for Plex, so do not use PrivateNetwork either.
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ stateDir ];
          ProtectControlGroups = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          RestrictSUIDSGID = true;
        };
      };
    };
}

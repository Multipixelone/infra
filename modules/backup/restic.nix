{ lib, inputs, ... }:
{
  flake.modules.nixos.pc =
    { pkgs, config, ... }:
    let
      cfg = config.infra.backup;
      rclone = config.infra.rclone;
      default-restic-options = {
        initialize = true;
        inherit (cfg) repository;

        # The mutable state config (see backup/rclone.nix), NOT the agenix
        # path — token rotation during a backup run must persist. The restic
        # module scopes this as a per-unit RCLONE_CONFIG.
        rcloneConfigFile = rclone.configFile;
        passwordFile = config.age.secrets."restic/password".path;

        extraBackupArgs = [
          "--one-file-system"
          "--exclude-caches"
          "--retry-lock 2h"
        ];

        pruneOpts = [
          "--keep-daily 14"
          "--keep-weekly 8"
          "--keep-monthly 12"
          "--keep-yearly 5"
        ];
        timerConfig = {
          OnCalendar = "00:00";
          Persistent = true;
          RandomizedDelaySec = "20m";
        };
      };

      resticUnits = [
        "restic-backups-home"
        "restic-check-repo"
      ]
      ++ lib.optional (cfg.srvPaths != [ ]) "restic-backups-srv";

      # Interactive snapshots/restore against the real repo, replacing the old
      # global RESTIC_*/RCLONE_CONFIG environment.variables (which pointed at
      # root-0400 files no user shell could read anyway).
      restic-onedrive = pkgs.writeShellApplication {
        name = "restic-onedrive";
        text = ''
          exec /run/wrappers/bin/sudo env \
            RCLONE_CONFIG=${rclone.configFile} \
            ${lib.getExe config.services.restic.backups.home.package} \
            -r ${cfg.repository} \
            -p ${default-restic-options.passwordFile} \
            "$@"
        '';
      };
    in
    {
      options.infra.backup = {
        repository = lib.mkOption {
          type = lib.types.str;
          default = "rclone:${rclone.remote}:Backups/${config.networking.hostName}";
          description = "restic repository string used by every backup unit and wrapper.";
        };
        srvPaths = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          description = "Service state dirs contributed by their owning modules (e.g. /srv/slskd).";
        };
      };

      config = {
        age.secrets."restic/password".file = "${inputs.secrets}/restic/password.age";

        environment.systemPackages = [ restic-onedrive ];

        systemd.services = lib.mkMerge [
          # Unified wiring for every rclone-consuming restic unit: pinned
          # rclone, seed-before-run, and fail-loud.
          (lib.genAttrs resticUnits (_: {
            path = [ rclone.package ];
            wants = [ "rclone-seed.service" ];
            after = [ "rclone-seed.service" ];
            onFailure = [ "notify-telegram@%n.service" ];
          }))
          {
            restic-check-repo.serviceConfig = {
              Type = "oneshot";
              ExecStart = "${lib.getExe config.services.restic.backups.home.package} -r ${cfg.repository} -p ${default-restic-options.passwordFile} check --read-data-subset=25%";
              Environment = "RCLONE_CONFIG=${rclone.configFile}";
            };
          }
        ];
        systemd.timers.restic-check-repo = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "monthly";
            Persistent = true;
          };
        };

        services.restic.backups = {
          home = default-restic-options // {
            paths = [
              "/home/tunnel"
            ];
            exclude = [
              ".local/share/Steam"
              ".local/share/baloo"
              ".local/share/flatpak"
              ".local/share/Trash"
              ".local/share/bottles"
              ".local/share/lutris/runners"
              ".config/steamtinkerlaunch"
              ".config/libvirt"
              ".config/Ryujinx"
              ".config/discord"
              "Documents/Git"
              "Music/Library"
              "Downloads"
              ".var/app"
              ".mozilla"
              ".cargo"
              ".winebroke"
              "Games"
            ];
          };
          # Paths contributed per service module via infra.backup.srvPaths.
          # Staggered an hour after `home` so two rclone processes never
          # refresh the rotating onedrive token concurrently.
          srv = lib.mkIf (cfg.srvPaths != [ ]) (
            default-restic-options
            // {
              paths = cfg.srvPaths;
              timerConfig = default-restic-options.timerConfig // {
                OnCalendar = "01:00";
              };
            }
          );
        };
      };
    };
}

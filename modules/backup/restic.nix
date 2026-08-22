{ lib, inputs, ... }:
{
  flake.modules.nixos.pc =
    { pkgs, config, ... }:
    let
      cfg = config.infra.backup;
      rclone = config.infra.rclone;

      # Retention policy. Deliberately NOT passed as `pruneOpts` on the backup
      # units: the NixOS restic module appends `forget --prune` as a further
      # ExecStart line on the same service, and systemd aborts the unit on the
      # first failing line. So a repo-side prune failure marks the unit failed
      # even when the snapshot was written seconds earlier, which is exactly
      # what happened here — `restic-backups-home` reported failure on 29
      # consecutive nights from 2026-07-27 while every one of those runs had
      # already logged "snapshot ... saved". A real backup failure would have
      # been indistinguishable from the noise, and the Telegram sink had been
      # crying wolf long enough to be ignored.
      #
      # Prune therefore runs as its own unit below. Backup units now report
      # backup health only; prune health is reported separately.
      retentionOpts = [
        "--keep-daily 14"
        "--keep-weekly 8"
        "--keep-monthly 12"
        "--keep-yearly 5"
      ];

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

        timerConfig = {
          OnCalendar = "00:00";
          Persistent = true;
          RandomizedDelaySec = "20m";
        };
      };

      resticUnits = [
        "restic-backups-home"
        "restic-check-repo"
        "restic-prune"
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

            # Repo-wide retention, split out of the backup units (see
            # retentionOpts above). One prune for the whole repository rather
            # than one per backup set: `home` and `srv` share a repository, so
            # two prunes only contended for the same lock. restic's default
            # `--group-by host,paths` still applies the policy to each snapshot
            # set independently, so behaviour is unchanged.
            restic-prune.serviceConfig = {
              Type = "oneshot";
              ExecStart = "${lib.getExe config.services.restic.backups.home.package} -r ${cfg.repository} -p ${default-restic-options.passwordFile} forget --prune --retry-lock 2h ${lib.concatStringsSep " " retentionOpts}";
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

        # 03:00 — clear of `home` (00:00 +20m jitter) and `srv` (01:00), so the
        # prune never races a backup for the repo lock or the rotating onedrive
        # token.
        systemd.timers.restic-prune = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "03:00";
            Persistent = true;
            RandomizedDelaySec = "20m";
          };
        };

        services.restic.backups = {
          # OpenClaw durability (answers ADDITIONS #6, "verify the home-dir
          # backup covers state/*.json"): it does, and no separate timer is
          # wanted. `/home/tunnel` is backed up whole and none of the excludes
          # below touch `~/.openclaw`, so the canonical daily state
          # (~/.openclaw/workspace/state/today.json), the agent workspaces,
          # sessions and credentials are all in every nightly snapshot. There
          # is deliberately no second copy anywhere — one canonical location,
          # one backup path.
          #
          # Secrets are handled by staying encrypted rather than by exclusion:
          # ~/.openclaw/credentials and the agenix runtime paths never enter
          # git, and restic encrypts the repository client-side with
          # age-managed `restic/password`. Nothing here is readable at rest by
          # the storage provider.
          #
          # Restore (needs the repo password; runs as root):
          #   restic-onedrive snapshots
          #   restic-onedrive restore <id> --target /tmp/r \
          #     --include /home/tunnel/.openclaw/workspace/state
          # `restic-onedrive` (defined above) wraps repo + password + rclone
          # config, so no credentials need to be typed or exported.
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

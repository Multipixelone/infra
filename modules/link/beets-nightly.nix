{ config, lib, ... }:
let
  owner = config.flake.meta.owner.username;
in
{
  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      home = config.home-manager.users.${owner};
      cfg = config.services.beets.nightly;
      beetsDirectory = builtins.dirOf home.programs.beets.settings.library;
      workers = [
        "beets-xtractor-backfill.service"
      ]
      ++ lib.optional config.services.beets.embedBackfill.enable "beets-embed-backfill.service";
    in
    {
      options.services.beets.nightly = {
        cpuQuotaPercent = lib.mkOption {
          type = lib.types.ints.positive;
          default =
            config.services.beets.xtractorBackfill.cpuQuotaPercent
            + config.services.beets.embedBackfill.cpuQuotaPercent;
          description = "Aggregate CPU quota for the nightly backfills; 100 is one logical CPU.";
        };
        memoryHigh = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "8G";
          description = "Optional aggregate systemd MemoryHigh for nightly backfills; unset until measured.";
        };
      };
      config = {
        # A direct batch child shares one budget across both nightly jobs.
        systemd.slices.batch-beets.sliceConfig = {
          CPUQuota = "${toString cfg.cpuQuotaPercent}%";
          CPUWeight = 10;
          IOWeight = 10;
        }
        // lib.optionalAttrs (cfg.memoryHigh != null) { MemoryHigh = cfg.memoryHigh; };
        systemd.targets.beets-nightly = {
          description = "Run both nightly Beets backfills";
          wants = workers;
          # Workers require the target while running. Once both finish it can
          # become inactive, so the next night's start can pull in both again.
          unitConfig.StopWhenUnneeded = true;
        };
        systemd.tmpfiles.rules = [ "d ${beetsDirectory} 0700 ${owner} users - -" ];
        systemd.services.beets-xtractor-backfill = {
          description = "Backfill xtractor analysis in the beets database";
          after = [ "systemd-tmpfiles-setup.service" ];
          requires = [ "beets-nightly.target" ];
          partOf = [ "beets-nightly.target" ];
          environment = {
            HOME = home.home.homeDirectory;
            XDG_CONFIG_HOME = home.xdg.configHome;
            XDG_DATA_HOME = home.xdg.dataHome;
            XDG_CACHE_HOME = "/tmp/beets-xtractor-cache";
            TZ = "America/New_York";
            TZDIR = "${pkgs.tzdata}/share/zoneinfo";
            PYTHONDONTWRITEBYTECODE = "1";
          };
          serviceConfig = {
            Type = "exec";
            User = owner;
            Group = "users";
            Slice = "batch-beets.slice";
            ExecStart = lib.getExe home.programs.beets.xtractorBackfillPackage;
            RuntimeMaxSec = "8h";
            Nice = 10;
            CPUWeight = 10;
            CPUQuota = "${toString config.services.beets.xtractorBackfill.cpuQuotaPercent}%";
            IOSchedulingClass = "idle";
            KillSignal = "SIGTERM";
            KillMode = "control-group";
            TimeoutStopSec = "60s";
            SuccessExitStatus = [
              "124"
              "143"
            ];
            Restart = "no";
            UMask = "0077";
            NoNewPrivileges = true;
            CapabilityBoundingSet = "";
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectSystem = "strict";
            ProtectHome = "read-only";
            ReadOnlyPaths = [ home.programs.beets.settings.directory ];
            ReadWritePaths = [ beetsDirectory ];
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            RestrictNamespaces = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            PrivateNetwork = true;
            RestrictAddressFamilies = [ "AF_UNIX" ];
          };
        };
        systemd.timers.beets-xtractor-backfill = {
          description = "Schedule the nightly DB-only xtractor backfill";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 01:00:00 America/New_York";
            Persistent = false;
            RandomizedDelaySec = 0;
            AccuracySec = "1s";
          };
        };
        systemd.services.beets-xtractor-backfill-stop = {
          description = "Stop nightly xtractor before 09:00 local, including after resume";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe' pkgs.systemd "systemctl"} stop beets-xtractor-backfill.service";
            TimeoutStartSec = "90s";
          };
        };
        systemd.timers.beets-xtractor-backfill-stop = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 08:58:59 America/New_York";
            Persistent = false;
            RandomizedDelaySec = 0;
            AccuracySec = "1s";
          };
        };
      };
    };
}

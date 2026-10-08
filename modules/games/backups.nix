{ lib, ... }:
{
  flake.modules.nixos.games-backups =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      secret = "games/restic-password";
      enabled =
        cfg.backup.enable
        && builtins.hasAttr secret cfg.secretFiles
        && builtins.pathExists cfg.secretFiles.${secret};
      servers = lib.filterAttrs (_: s: s.backup && s.available) cfg.runtime;
      scheduledIds = lib.attrNames (lib.filterAttrs (_: s: s.backup) cfg.runtime);
      calendarFor =
        id:
        let
          index = lib.lists.findFirstIndex (name: name == id) 0 scheduledIds;
          minute = 30 + index * 10;
          pad = number: lib.fixedWidthString 2 "0" (toString number);
        in
        "${pad (builtins.div minute 60)}:${pad (lib.mod minute 60)}";
    in
    {
      config = lib.mkIf enabled {
        # Reuses the same export and automount as the existing desktop module;
        # this declaration also makes the backend movable to a server-role host.
        boot.supportedFilesystems = [ "nfs" ];
        fileSystems."/media/alexandria" = {
          device = "192.168.6.9:/volume1/homes/tunnel";
          fsType = "nfs";
          options = lib.mkDefault [
            "nfsvers=4.1"
            "x-systemd.automount"
            "noauto"
          ];
        };
        services.restic.backups = lib.mapAttrs' (
          id: _:
          lib.nameValuePair "games-${id}" {
            initialize = false;
            repository = cfg.backup.repository;
            passwordFile = "/run/agenix/${secret}";
            paths = cfg.runtime.${id}.worldPaths;
            # Our wrapper owns consistency and recovery across the entire run.
            timerConfig = {
              OnCalendar = calendarFor id;
              Persistent = true;
              RandomizedDelaySec = "2m";
            };
          }
        ) servers;
        systemd.services =
          lib.mapAttrs' (
            id: _:
            lib.nameValuePair "restic-backups-games-${id}" {
              unitConfig.RequiresMountsFor = [ "/media/alexandria" ];
              # GameBackupUnhealthy owns per-world notifications and freshness.
              serviceConfig = {
                Slice = "games-backup.slice";
                ExecStart = lib.mkForce [ "${lib.getExe cfg.packages.backup-run} ${id}" ];
                ExecStopPost = lib.mkBefore [ "${lib.getExe cfg.packages.recover} ${id}" ];
                TimeoutStartSec = "40min";
                TimeoutStopSec = "6min";
              };
            }
          ) servers
          // {
            games-restic-prune = {
              description = "Retain seven daily and four weekly game snapshots";
              after = map (id: "restic-backups-games-${id}.service") (lib.attrNames servers);
              unitConfig.RequiresMountsFor = [ "/media/alexandria" ];
              onFailure = [ "notify-telegram@%n.service" ];
              serviceConfig = {
                Type = "oneshot";
                Slice = "games-backup.slice";
                ExecStart = "${lib.getExe cfg.packages.prune}";
                TimeoutStartSec = "30min";
              };
            };
          };
        systemd.timers.games-restic-prune = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "00:55";
            Persistent = true;
            RandomizedDelaySec = "5m";
          };
        };
      };
    };
}

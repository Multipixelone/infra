{ lib, ... }:
let
  patterns = builtins.fromJSON (builtins.readFile ./log-patterns.json);
in
{
  flake.modules.nixos.games-observability =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      registered = cfg.registeredServers // cfg.servers;
      bytes =
        value:
        let
          parts = builtins.match "([0-9]+)([MG])" value;
        in
        lib.toInt (builtins.elemAt parts 0)
        * (if builtins.elemAt parts 1 == "G" then 1073741824 else 1048576);
      backupReady =
        cfg.backup.enable
        && cfg.secretFiles ? "games/restic-password"
        && builtins.pathExists cfg.secretFiles."games/restic-password";
      servers =
        lib.mapAttrs (
          id: s:
          let
            runtime = cfg.runtime.${id} or { };
          in
          {
            inherit (s) game;
            enabled = s.enable;
            available = runtime.available or false;
            unit =
              runtime.unit or (
                if s.game == "minecraft-paper" then
                  "minecraft-server-${id}.service"
                else
                  "podman-games-${id}.service"
              );
            container = runtime.container or null;
            wakeOnJoin = runtime.wakeOnJoin or (s.game == "minecraft-paper");
            serverPort =
              runtime.serverPort
                or (if s.game == "minecraft-paper" then s.minecraft.serverPort else s.terraria.port);
            childExitFile = runtime.childExitFile or "/run/games/${id}/paper-exit.json";
            secretPaths = map (name: "/run/agenix/${name}") (runtime.secretNames or [ ]);
            capacity = if s.game == "minecraft-paper" then s.minecraft.maxPlayers else s.terraria.maxPlayers;
            memoryBytes = bytes s.memoryMax;
            backupEnabled = backupReady && s.backup;
          }
        ) registered
        // lib.optionalAttrs (cfg.proxy != { }) {
          velocity = {
            game = "minecraft-velocity";
            enabled = true;
            inherit (cfg.proxy) available unit;
            container = null;
            wakeOnJoin = false;
            serverPort = 25565;
            secretPaths = map (name: "/run/agenix/${name}") cfg.proxy.secretNames;
            memoryBytes = 1073741824;
            backupEnabled = false;
          };
        };
      inventory = {
        inherit servers patterns;
        host = config.networking.hostName;
        cgroupRoot = "/sys/fs/cgroup";
        backupStateDir = "/srv/games/.state";
        backupPasswordPath = "/run/agenix/games/restic-password";
        commands = {
          status = lib.getExe cfg.packages.status;
          systemctl = "${pkgs.systemd}/bin/systemctl";
          journalctl = "${pkgs.systemd}/bin/journalctl";
          podman = lib.getExe pkgs.podman;
        };
      };
      inventoryFile = pkgs.writeText "games-observability-inventory.json" (builtins.toJSON inventory);
      exporter = pkgs.writeShellApplication {
        name = "games-metrics";
        text = ''
          exec ${pkgs.python3}/bin/python3 ${./metrics.py} \
            --inventory ${inventoryFile} \
            --state /var/lib/games-metrics/state.json \
            --output /var/lib/prometheus-node-exporter-text-files/games.prom
        '';
      };
      quote = builtins.toJSON;
      relabel = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          id: item:
          let
            unitRegex = "(${
              lib.concatStringsSep "|" (
                map lib.escapeRegex (
                  [ item.unit ] ++ lib.optional (id != "velocity") "restic-backups-games-${id}.service"
                )
              )
            })";
            rule = source: regex: target: replacement: ''
              rule {
                source_labels = [${quote source}]
                regex = ${quote regex}
                target_label = ${quote target}
                replacement = ${quote replacement}
              }
            '';
            labels =
              source: regex:
              rule source regex "server_id" id
              + rule source regex "game" item.game
              + rule source regex "service_name" "games";
          in
          labels "unit" unitRegex
          + labels "__journal_unit" unitRegex
          + rule "__journal_unit" unitRegex "unit" "$1"
          + labels "__journal_coredump_unit" unitRegex
          + rule "__journal_coredump_unit" unitRegex "unit" "$1"
          + lib.optionalString (item.container != null) (
            labels "__journal_container_name" (lib.escapeRegex item.container)
          )
        ) servers
      );
      stages = ''
        stage.match {
          selector = "{service_name=\"games\"}"
          stage.replace {
            expression = ${quote "(?i)((?:rcon[._ -]?(?:password|secret)|forwarding[._ -]?secret|password|authorization|token|api[_-]?key|secret)[\\\"'=: ]+)([^,;\\r\\n]+)"}
            replace = "[REDACTED]"
          }
          stage.static_labels {
            values = { event = "console" }
          }
        }
      ''
      + lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          game: events:
          lib.concatStringsSep "\n" (
            lib.mapAttrsToList (event: regex: ''
              stage.match {
                selector = ${quote ''{service_name="games",game="${game}"} |~ ${quote regex}''}
                stage.static_labels {
                  values = { event = ${quote event} }
                }
              }
            '') events
          )
        ) patterns
      );
    in
    {
      options.infra.games.observability = {
        inventory = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          internal = true;
        };
        journalRelabel = lib.mkOption {
          type = lib.types.str;
          default = "";
          internal = true;
        };
        journalStages = lib.mkOption {
          type = lib.types.str;
          default = "";
          internal = true;
        };
      };
      config = lib.mkIf (servers != { } && config.networking.hostName == "link") {
        infra.games.observability = {
          inherit inventory;
          journalRelabel = relabel;
          journalStages = stages;
        };
        infra.games.packages.metrics = exporter;
        systemd.services.games-metrics = {
          description = "Publish passive game server telemetry";
          after = [ "prometheus-node-exporter.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe exporter;
            StateDirectory = "games-metrics";
            StateDirectoryMode = "0700";
            UMask = "0077";
            TimeoutStartSec = "25s";
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            # Podman inspect needs its existing storage/runtime locks.
            ReadWritePaths = [
              "/var/lib/games-metrics"
              "/var/lib/prometheus-node-exporter-text-files"
              "-/run/containers"
              "-/var/lib/containers/storage"
            ];
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
              "AF_NETLINK"
            ];
          };
        };
        systemd.timers.games-metrics = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "30s";
            OnUnitInactiveSec = "30s";
            AccuracySec = "1s";
          };
        };
      };
    };
}

{ config, lib, ... }:
{
  flake.modules.nixos.games-dashboard =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      secret = "games/restic-password";
      backupEnabled =
        cfg.backup.enable
        && builtins.hasAttr secret cfg.secretFiles
        && builtins.pathExists cfg.secretFiles.${secret};
      inventory = pkgs.writeText "games-runtime.json" (
        builtins.toJSON {
          servers = cfg.runtime;
          proxy = cfg.proxy;
          backup = {
            enabled = backupEnabled;
            repository = cfg.backup.repository;
            passwordFile = "/run/agenix/${secret}";
            source = "192.168.6.9:/volume1/homes/tunnel";
          };
          stateDir = "/srv/games/.state";
          runDir = "/run/games";
          commands = {
            systemctl = "${pkgs.systemd}/bin/systemctl";
            journalctl = "${pkgs.systemd}/bin/journalctl";
            restic = lib.getExe pkgs.restic;
            podman = lib.getExe pkgs.podman;
            findmnt = "${pkgs.util-linux}/bin/findmnt";
          };
        }
      );
      helper =
        name: verb:
        pkgs.writeShellApplication {
          inherit name;
          text = ''exec ${pkgs.python3}/bin/python3 ${./runtime.py} --inventory ${inventory} ${verb} "$@"'';
        };
      journalReader = helper "games-journal-reader" "logs";
      privilegedConsole = helper "games-console-writer" "console-root";
      packages = {
        prepare = helper "games-prepare" "prepare";
        prechange = helper "games-prechange" "prechange";
        paper-stop = helper "games-paper-stop" "paper-stop";
        container-stop = helper "games-container-stop" "container-stop";
        container-result = helper "games-container-result" "container-result";
        backup-run = helper "games-backup-run" "backup-run";
        recover = helper "games-backup-recover" "recover";
        prune = helper "games-prune" "prune";
        status = helper "games-status" "status";
        backup = helper "games-backup" "backup";
        console = pkgs.writeShellApplication {
          name = "games-console";
          text = ''exec ${pkgs.python3}/bin/python3 ${./runtime.py} --inventory ${inventory} console ${lib.getExe privilegedConsole} "$@"'';
        };
        logs = pkgs.writeShellApplication {
          name = "games-logs";
          text = ''exec /run/wrappers/bin/sudo -n ${lib.getExe journalReader} "$@"'';
        };
      };
      controlUnits =
        map (s: s.unit) (lib.attrValues cfg.runtime) ++ lib.optional (cfg.proxy != { }) cfg.proxy.unit;
      backupUnits = map (id: "restic-backups-games-${id}.service") (
        lib.attrNames (lib.filterAttrs (_: s: s.backup && s.available && backupEnabled) cfg.runtime)
      );
      manifest = {
        schemaVersion = 1;
        host = config.networking.hostName;
        sharedServices = lib.optional (cfg.proxy != { }) {
          id = "velocity";
          inherit (cfg.proxy) unit available;
          logsCommand = [
            "games-logs"
            "velocity"
          ];
        };
        servers = lib.mapAttrsToList (id: s: {
          inherit (s)
            game
            displayName
            public
            unit
            container
            dataDir
            worldPaths
            wakeOnJoin
            available
            ;
          inherit id;
          console = s.console // {
            command = [
              "games-console"
              id
            ];
          };
          backup = {
            enabled = backupEnabled && s.backup && s.available;
            unit = "restic-backups-games-${id}.service";
            command = [
              "games-backup"
              id
            ];
          };
          statusCommand = [
            "games-status"
            id
          ];
          logsCommand = [
            "games-logs"
            id
          ];
        }) cfg.runtime;
      };
    in
    {
      infra.games.packages = packages;
      environment.systemPackages = lib.attrValues packages;
      environment.etc."games/manifest.json".text = builtins.toJSON manifest + "\n";
      security.polkit.extraConfig = lib.mkBefore ''
        polkit.addRule(function(action, subject) {
          if (subject.user !== "games-dashboard") return polkit.Result.NOT_HANDLED;
          if (action.id === "org.freedesktop.systemd1.manage-units") {
            var unit = action.lookup("unit");
            var verb = action.lookup("verb");
            if (${builtins.toJSON controlUnits}.indexOf(unit) !== -1 &&
                ["start", "stop", "restart"].indexOf(verb) !== -1) return polkit.Result.YES;
            if (${builtins.toJSON backupUnits}.indexOf(unit) !== -1 && verb === "start") return polkit.Result.YES;
          }
          return polkit.Result.NO;
        });
      '';
      security.sudo.extraRules = [
        {
          users = [ "games-dashboard" ];
          runAs = "root";
          commands =
            map
              (p: {
                command = lib.getExe p;
                options = [ "NOPASSWD" ];
              })
              [
                journalReader
                privilegedConsole
              ];
        }
      ];
    };
  perSystem = { ... }: {
    packages =
      lib.mapAttrs' (
        _: package: lib.nameValuePair package.name package
      ) config.flake.nixosConfigurations.link.config.infra.games.packages
      // config.flake.nixosConfigurations.link.config.infra.games.artifacts;
  };
}

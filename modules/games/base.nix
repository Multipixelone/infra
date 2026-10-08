{ lib, ... }:
{
  flake.modules.nixos.games-base =
    { config, ... }:
    let
      cfg = config.infra.games;
      secretReady = name: cfg.secretFiles ? ${name} && builtins.pathExists cfg.secretFiles.${name};
      requiredSecrets =
        lib.unique (lib.concatMap (s: s.secretNames) (lib.attrValues cfg.runtime))
        ++ lib.optional cfg.backup.enable "games/restic-password";
      ports =
        lib.optional (cfg.proxy != { }) 25565
        ++ lib.optional (cfg.proxy != { }) 19132
        ++ lib.concatMap (s: s.internalPorts ++ s.publicTCPPorts ++ s.publicUDPPorts) (
          lib.attrValues cfg.runtime
        );
    in
    {
      options.infra.games = {
        servers = lib.mkOption {
          type = lib.types.attrs;
          default = { };
        };
        secretFiles = lib.mkOption {
          type = lib.types.attrsOf lib.types.path;
          default = { };
        };
        defaultServer = lib.mkOption {
          type = lib.types.str;
          default = "survival";
        };
        backup = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
          };
          repository = lib.mkOption {
            type = lib.types.str;
            default = "/media/alexandria/Backups/games";
          };
        };
        runtime = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          internal = true;
          description = "Adapter output consumed by backups, helpers, and the manifest.";
        };
        proxy = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          internal = true;
        };
        packages = lib.mkOption {
          type = lib.types.attrsOf lib.types.package;
          default = { };
          internal = true;
        };
        artifacts = lib.mkOption {
          type = lib.types.attrsOf lib.types.package;
          default = { };
          internal = true;
          description = "Pinned game packages exposed as explicit build installables.";
        };
      };
      config = {
        assertions = [
          {
            assertion = builtins.length ports == builtins.length (lib.unique ports);
            message = "game server listening ports collide";
          }
        ];
        systemd.slices = {
          games.sliceConfig = {
            CPUAccounting = true;
            MemoryAccounting = true;
            CPUWeight = 200;
            IOWeight = 100;
          };
          games-backup.sliceConfig = {
            CPUWeight = 20;
            IOWeight = 20;
          };
        };
        users.groups.games-dashboard = { };
        users.users.games-dashboard = {
          isSystemUser = true;
          group = "games-dashboard";
        };
        systemd.tmpfiles.rules = [
          "d /srv/games 0755 root root -"
          "d /srv/games/.state 0700 root root -"
          "d /run/games 0755 root root -"
          "d /run/games/locks 0755 root root -"
        ];
        networking.firewall = {
          allowedTCPPorts =
            lib.unique (lib.concatMap (s: s.publicTCPPorts) (lib.attrValues cfg.runtime))
            ++ lib.optional (cfg.proxy != { }) 25565;
          allowedUDPPorts =
            lib.unique (lib.concatMap (s: s.publicUDPPorts) (lib.attrValues cfg.runtime))
            ++ lib.optional (cfg.proxy != { }) 19132;
        };
        age.secrets = lib.genAttrs (lib.filter secretReady requiredSecrets) (name: {
          file = cfg.secretFiles.${name};
          owner = if lib.hasPrefix "games/minecraft/" name then "minecraft" else "root";
          group =
            if lib.hasSuffix "-rcon" name then
              "games-dashboard"
            else if lib.hasPrefix "games/minecraft/" name then
              "minecraft"
            else
              "root";
          mode = if lib.hasSuffix "-rcon" name then "0440" else "0400";
        });
      };
    };
}

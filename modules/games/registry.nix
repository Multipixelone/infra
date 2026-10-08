{
  config,
  lib,
  inputs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.gameServers;
  idType = types.strMatching "[a-z][a-z0-9_]*";
  uuidType = types.strMatching "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";
  serverType = types.submodule (
    { name, config, ... }: {
      options = {
        enable = mkOption {
          type = types.bool;
          default = true;
        };
        game = mkOption { type = types.str; };
        displayName = mkOption {
          type = types.str;
          default = name;
        };
        targetHost = mkOption {
          type = types.str;
          default = cfg.targetHost;
        };
        hostnames = mkOption { type = types.nonEmptyListOf (types.strMatching "[a-z0-9.-]+"); };
        memoryMax = mkOption {
          type = types.strMatching "[1-9][0-9]*[MG]";
          default = if config.game == "minecraft-paper" then "6G" else "4G";
        };
        backup = mkOption {
          type = types.bool;
          default = true;
        };
        minecraft = {
          version = mkOption {
            type = types.str;
            default = "26.3";
          };
          package = mkOption {
            type = types.nullOr types.package;
            default = null;
          };
          proxyPort = mkOption {
            type = types.port;
            default = 25566;
          };
          serverPort = mkOption {
            type = types.port;
            default = 25567;
          };
          rconPort = mkOption {
            type = types.port;
            default = 25575;
          };
          jvmOpts = mkOption {
            type = types.str;
            default = "-Xms1G -Xmx4G";
          };
          whitelist = mkOption {
            type = types.attrsOf uuidType;
            default = { };
          };
          operators = mkOption {
            type = types.attrsOf uuidType;
            default = { };
          };
          plugins = mkOption {
            type = types.attrsOf types.path;
            default = { };
          };
        };
        terraria = {
          port = mkOption {
            type = types.port;
            default = 7777;
          };
          image = mkOption {
            type = types.strMatching ".+@sha256:[0-9a-f]{64}";
            default = "docker.io/jacobsmile/tmodloader1.4:v2026.08.3.0@sha256:ec3084193f4f9fa0d2a0d1415acd94667a8912bd59de0081270b40398d641f3e";
          };
          worldName = mkOption {
            type = types.strMatching "[a-zA-Z0-9_-]+";
            default = "Finn";
          };
          worldSize = mkOption {
            type = types.ints.between 1 3;
            default = 2;
          };
          difficulty = mkOption {
            type = types.ints.between 0 3;
            default = 1;
          };
          maxPlayers = mkOption {
            type = types.ints.positive;
            default = 16;
          };
          mods = mkOption {
            type = types.attrsOf types.path;
            default = { };
            description = "Internal mod name to a pinned .tmod artifact; no runtime Workshop updates.";
          };
          modConfigs = mkOption {
            type = types.attrs;
            default = { };
          };
        };
      };
    }
  );
  hosts = lib.unique (map (s: s.targetHost) (lib.attrValues cfg.servers));
  secrets = {
    "games/dashboard-htpasswd" = "${inputs.secrets}/games/dashboard-htpasswd.age";
    "games/minecraft/velocity-forwarding" = "${inputs.secrets}/games/minecraft/velocity-forwarding.age";
    "games/minecraft/floodgate-key" = "${inputs.secrets}/games/minecraft/floodgate-key.age";
    "games/restic-password" = "${inputs.secrets}/games/restic-password.age";
  }
  // lib.listToAttrs (
    lib.mapAttrsToList (id: server: {
      name =
        if server.game == "minecraft-paper" then
          "games/minecraft/${id}-rcon"
        else
          "games/terraria/${id}-password";
      value =
        if server.game == "minecraft-paper" then
          "${inputs.secrets}/games/minecraft/${id}-rcon.age"
        else
          "${inputs.secrets}/games/terraria/${id}-password.age";
    }) cfg.servers
  );
in
{
  options.gameServers = {
    targetHost = mkOption {
      type = types.str;
      default = "link";
    };
    servers = mkOption {
      type = types.attrsOf serverType;
      default = { };
    };
    adapters = mkOption {
      type = types.attrsOf types.deferredModule;
      default = { };
    };
    secretFiles = mkOption {
      type = types.attrsOf types.path;
      default = secrets;
    };
    minecraft.defaultServer = mkOption {
      type = idType;
      default = "survival";
    };
    backup = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable only after initializing the NAS repository and creating games/restic-password.age.";
      };
      repository = mkOption {
        type = types.str;
        default = "/media/alexandria/Backups/games";
      };
    };
  };
  config = {
    gameServers = {
      adapters = {
        minecraft-paper = config.flake.modules.nixos.games-minecraft;
        terraria-tmodloader = config.flake.modules.nixos.games-tmodloader;
      };
      servers = {
        survival = {
          game = "minecraft-paper";
          displayName = "Survival";
          hostnames = [
            "survival.mc.finnrut.is"
            "mc.finnrut.is"
          ];
        };
        terraria = {
          game = "terraria-tmodloader";
          displayName = "Terraria";
          hostnames = [ "terraria.finnrut.is" ];
        };
      };
    };
    configurations.nixos = lib.genAttrs hosts (host: {
      module = {
        imports = [
          config.flake.modules.nixos.games-base
          config.flake.modules.nixos.games-backups
          config.flake.modules.nixos.games-dashboard
        ]
        ++ lib.attrValues cfg.adapters;
        infra.games = {
          servers = lib.filterAttrs (_: s: s.enable && s.targetHost == host) cfg.servers;
          inherit (cfg) secretFiles backup;
          defaultServer = cfg.minecraft.defaultServer;
        };
        assertions = [
          {
            assertion = builtins.hasAttr host config.hosts;
            message = "game server target ${host} is not registered";
          }
          {
            assertion = lib.all (id: builtins.match "[a-z][a-z0-9_]*" id != null) (lib.attrNames cfg.servers);
            message = "game server IDs must be stable lowercase identifiers";
          }
          {
            assertion = !(cfg.servers ? velocity);
            message = "velocity is reserved for the shared Minecraft proxy";
          }
          {
            assertion = lib.all (
              s: lib.all (name: builtins.match "[A-Za-z0-9_.-]+" name != null) (lib.attrNames s.minecraft.plugins)
            ) (lib.attrValues cfg.servers);
            message = "Minecraft plugin names must be simple filenames without directories";
          }
          {
            assertion = lib.all (s: builtins.hasAttr s.game cfg.adapters) (lib.attrValues cfg.servers);
            message = "game server references an unknown adapter";
          }
        ];
      };
    });
  };
}

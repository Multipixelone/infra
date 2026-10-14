{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      format = pkgs.formats.yaml { };
      # WorldEditPlugin reads this separate file, not FAWE's config.yml.
      # Preserve the pinned jar's complete defaults while freeing survival tools.
      worldeditConfiguration =
        pkgs.runCommand "worldedit-config.yml"
          {
            nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ];
          }
          ''
            python3 - ${cfg.artifacts.games-fawe} "$out" <<'PY'
            import sys
            import zipfile
            import yaml

            with zipfile.ZipFile(sys.argv[1]) as jar:
                configuration = yaml.safe_load(jar.read("defaults/worldedit-config.yml"))
            configuration["wand-item"] = "minecraft:breeze_rod"
            # Admin's wildcard permission also enables compass click interception.
            configuration["navigation-wand"]["item"] = "minecraft:blaze_rod"
            with open(sys.argv[2], "w") as output:
                yaml.safe_dump(configuration, output, sort_keys=False)
            PY
          '';
      # Both profiles are bounded: the fallback must not restore upstream's
      # 50-million-block limit when a player lacks fawe.limit.builder.
      limits = {
        max-actions = 1;
        max-changes = 100000;
        max-checks = 1000000;
        max-fails = 100000;
        max-iterations = 10;
        max-entities = 0;
        max-blockstates = 1000;
        max-radius = 32;
        max-brush-radius = 8;
        max-super-pickaxe-size = 8;
        max-butcher-radius = 8;
        max-history-mb = 128;
        inventory-mode = 0;
        confirm-large = true;
      };
      particles = {
        fade-delay = 0;
        max-selection-size = 100000;
        primary = {
          points-distance = 2.0;
          update-interval = 20;
          view-distance = 32;
          particles = {
            type = "FLAME";
            data = "";
          };
        };
        secondary = {
          points-distance = 4.0;
          lines-gap = 0.0;
          update-interval = 20;
          view-distance = 32;
          particles = {
            type = "FLAME";
            data = "";
          };
        };
        origin = {
          update-interval = 20;
          view-distance = 32;
          particles = {
            type = "FLAME";
            data = "";
          };
        };
      };
      configurations = {
        FastAsyncWorldEdit = {
          # No claims plugin is declared on this trusted friends server.
          region-restrictions = false;
          enabled-components = {
            snapshot-update-notifications = false;
            release-update-notifications = false;
            notify-update-ingame = false;
          };
          limits = {
            default = limits;
            builder = limits;
          };
          history = {
            use-disk = true;
            use-database = true;
            store-redo = true;
            delete-after-days = 7;
            delete-disk-on-logout = false;
          };
          clipboard.use-disk = true;
        };
        FastAsyncVoxelSniper = {
          config-version = 7;
          update-checker.enabled = false;
          message-on-login-enabled = false;
          default-brush-size = 3;
          litesniper-max-brush-size = 8;
          litesniper-restricted-materials = [
            "minecraft:barrier"
            "minecraft:bedrock"
          ];
          brush-size-warning-threshold = 8;
          brush-properties = {
            "Copy Pasta".block-limit = 100000;
            Move.max-block-count = 100000;
          };
        };
        WorldEditSelectionVisualizer = {
          check-updates = false;
          save-toggle = true;
          default-enabled = {
            selection = true;
            clipboard = false;
          };
          selection-update-interval = 20;
          need-we-wand = false;
          cuboid-top-bottom = false;
          # Bukkit particles require no Java client mod or display entities.
          visualization = {
            selection = particles;
            clipboard = particles;
          };
        };
      };
    in
    lib.mkIf (servers != { }) {
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        # FAWE provides WorldEdit; never install the EngineHub JAR alongside it.
        jars = {
          fawe = cfg.artifacts.games-fawe;
          voxelsniper = cfg.artifacts.games-voxelsniper;
          worldedit-visualizer = cfg.artifacts.games-worldedit-visualizer;
        };
        templates =
          lib.mapAttrs' (
            name: value:
            lib.nameValuePair "/srv/games/minecraft/${id}/plugins/${name}/config.yml" {
              source = toString (format.generate "${id}-${name}.yml" value);
            }
          ) configurations
          // {
            "/srv/games/minecraft/${id}/plugins/FastAsyncWorldEdit/worldedit-config.yml".source =
              toString worldeditConfiguration;
          };
        statePaths = map (name: "/srv/games/minecraft/${id}/plugins/${name}") (
          lib.attrNames configurations
        );
        inventory = [
          {
            name = "FastAsyncWorldEdit";
            version = "2.16.0";
            installed = true;
          }
          {
            name = "FastAsyncVoxelSniper";
            version = "3.2.5";
            installed = true;
          }
          {
            name = "WorldEditSelectionVisualizer";
            version = "2.1.10";
            installed = true;
          }
        ];
      }) servers;
    };
}

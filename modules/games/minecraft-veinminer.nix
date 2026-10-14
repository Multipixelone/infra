{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      definitions = builtins.fromJSON (builtins.readFile ./veinminer-libraries.json);
      # Keep collection metadata for evicted Kotlin versions, but only the 14
      # jars selected by the release's actual Maven resolver.
      libraries = map (
        d:
        d
        // {
          source = pkgs.fetchurl {
            name = builtins.baseNameOf d.path;
            inherit (d) url sha256;
          };
        }
      ) definitions;
      # The published Paper loader rewrites Maven Central URLs but keeps the
      # manifest's repository IDs. Preseed POMs/BOMs as well as runtime jars.
      cache = pkgs.runCommand "veinminer-2.12.3-libraries" { } (
        lib.concatMapStrings (d: ''
          mkdir -p "$out/${builtins.dirOf d.path}"
          ln -s ${d.source} "$out/${d.path}"
          echo '${builtins.baseNameOf d.path}>MavenRepo=' >> "$out/${builtins.dirOf d.path}/_remote.repositories"
        '') libraries
      );
      format = pkgs.formats.json { };
      settings = format.generate "veinminer-2.12.3-settings.json" {
        mustSneak = true;
        needCorrectTool = true;
        decreaseDurability = true;
        # One stack, including the first block, bounds stone deposits and work
        # per click. Radius one also connects diagonally touching ore blocks.
        maxChain = 64;
        searchRadius = 1;
        cooldown = 20;
        delay = 0;
        separateGroupMining = true;
        permissionRestricted = true;
        mergeItemDrops = false;
        hungerPerBlock = 0.0;
        miningSpeedModifier = 0.0;
        autoUpdate = false;
        # 2.12.3 still checks/downloads updates unconditionally. Finn accepted
        # the upstream behavior; this key suppresses join messages only.
        dontDisplayUpdatesAndIWillNotAskForSupportBeforeUpdatingISwear = true;
        debug = false;
        client = {
          allow = false;
          require = false;
          allBlocks = false;
          overrides = { };
        };
      };
      groups = format.generate "veinminer-2.12.3-groups.json" [
        {
          name = "Ores";
          blocks = map (name: "minecraft:${name}") (
            lib.concatMap
              (ore: [
                "${ore}_ore"
                "deepslate_${ore}_ore"
              ])
              [
                "coal"
                "copper"
                "iron"
                "gold"
                "redstone"
                "lapis"
                "diamond"
                "emerald"
              ]
            ++ [
              "nether_gold_ore"
              "nether_quartz_ore"
              "ancient_debris"
            ]
          );
          tools = [ "#minecraft:pickaxes" ];
        }
        {
          name = "Decorative stone";
          blocks = [
            "minecraft:diorite"
            "minecraft:andesite"
          ];
          tools = [ "#minecraft:pickaxes" ];
        }
      ];
      blocks = format.generate "veinminer-2.12.3-blocks.json" [ ];
    in
    lib.mkIf (servers != { }) {
      infra.games.artifacts.games-veinminer-libraries = cache;
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars.veinminer = cfg.artifacts.games-veinminer;
        templates = {
          "/srv/games/minecraft/${id}/plugins/Veinminer/settings.json".source = toString settings;
          "/srv/games/minecraft/${id}/plugins/Veinminer/groups.json".source = toString groups;
          "/srv/games/minecraft/${id}/plugins/Veinminer/blocks.json".source = toString blocks;
        };
        statePaths = [ "/srv/games/minecraft/${id}/plugins/Veinminer" ];
        inventory = [
          {
            name = "Veinminer";
            version = "2.12.3";
            installed = true;
          }
        ];
      }) servers;
      services.minecraft-servers.servers = lib.mapAttrs (_: _: {
        symlinks = lib.listToAttrs (
          map (path: lib.nameValuePair "libraries/${path}" "${cache}/${path}") (
            lib.unique (map (d: builtins.dirOf d.path) definitions)
          )
        );
      }) servers;
    };
}

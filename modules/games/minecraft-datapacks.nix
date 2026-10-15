{ lib, ... }:
let
  sources = builtins.fromJSON (builtins.readFile ./datapacks/sources.json);
in
{
  gitignore = [ "/modules/games/datapacks/*.zip" ];
  perSystem.treefmt.settings.global.excludes = [
    "modules/games/datapacks/grave-compass/**/*.mcfunction"
    "modules/games/datapacks/grave-compass/pack.mcmeta"
    "modules/games/datapacks/join-tips/**/*.mcfunction"
    "modules/games/datapacks/join-tips/pack.mcmeta"
  ];
  # requireFile marks manual inputs unfree; allow only this declared selection.
  nixpkgs.config.allowUnfreePackages = map (pack: pack.id) sources.packs;
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      # Archive bytes are supplied locally, never redistributed in this public repo.
      # Flat hashes and canonical basenames match nix-store --add-fixed imports.
      vanillaTweaks = lib.listToAttrs (
        map (
          pack:
          lib.nameValuePair pack.id (
            pkgs.requireFile {
              name = pack.archive;
              inherit (pack) sha256;
              hashMode = "flat";
              message = ''
                Missing official Vanilla Tweaks ${pack.name} ${pack.version} (MC 26.3).
                Obtain bundle ${sources.bundle.id} from ${sources.upstream}, extract
                "${pack.bundleEntry}", and rename the unchanged ZIP to ${pack.archive}.
                Expected SHA-256: ${pack.sha256}
                From the directory containing that file, run exactly:
                  nix-store --add-fixed sha256 ./${pack.archive}
                Provision each fresh builder/CI store this way; see docs/games-minecraft.md.
              '';
            }
          )
        ) sources.packs
      );
      # Load functions run on every Paper wake and /reload, after world data loads.
      policyFiles = {
        "pack.mcmeta" = builtins.toJSON {
          pack = {
            description = "Survival world policy: 50% sleeping";
            min_format = [
              121
              0
            ];
            max_format = [
              121
              0
            ];
          };
        };
        "data/minecraft/tags/function/load.json" = builtins.toJSON {
          values = [ "infra:world_policy" ];
        };
        "data/infra/function/world_policy.mcfunction" =
          "gamerule minecraft:players_sleeping_percentage 50\n";
      };
      policy = pkgs.runCommand "survival-world-policy-26.3.zip" { } ''
        ${pkgs.python3}/bin/python3 ${./minecraft-datapacks.py} build \
          ${pkgs.writeText "survival-world-policy-files.json" (builtins.toJSON policyFiles)} "$out"
      '';
      packFiles =
        directory:
        lib.listToAttrs (
          map (
            path:
            lib.nameValuePair (lib.removePrefix "${toString directory}/" (toString path)) (
              builtins.readFile path
            )
          ) (lib.filesystem.listFilesRecursive directory)
        );
      graveCompass = pkgs.runCommand "grave-compass-26.3.zip" { } ''
        ${pkgs.python3}/bin/python3 ${./minecraft-datapacks.py} build \
          ${pkgs.writeText "grave-compass-files.json" (builtins.toJSON (packFiles ./datapacks/grave-compass))} "$out"
      '';
      joinTips =
        id: s:
        let
          files =
            packFiles ./datapacks/join-tips
            // import ../../lib/minecraft-join-tips.nix {
              inherit lib;
              inherit (cfg.runtime.${id}) mapUrl;
              inherit (s.minecraft.discord) inviteUrl;
            };
        in
        pkgs.runCommand "join-tips-${id}-26.3.zip" { } ''
          ${pkgs.python3}/bin/python3 ${./minecraft-datapacks.py} build \
            ${pkgs.writeText "join-tips-${id}-files.json" (builtins.toJSON files)} "$out"
        '';
      installer = pkgs.writeScript "minecraft-datapacks-prepare" ''
        #!${pkgs.python3}/bin/python3
        import runpy
        runpy.run_path("${./minecraft-datapacks.py}", run_name="__main__")
      '';
    in
    {
      options.infra.games.minecraftDatapacks.backends = lib.mkOption {
        internal = true;
        default = { };
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              packs = lib.mkOption {
                type = lib.types.attrsOf lib.types.package;
                default = { };
                description = "Stable managed name to a pinned datapack ZIP.";
              };
              inventory = lib.mkOption {
                type = lib.types.listOf lib.types.attrs;
                default = [ ];
              };
            };
          }
        );
      };
      config = lib.mkIf (servers != { }) {
        # The installed system profile roots the inputs even when Paper is asleep.
        system.extraDependencies = lib.attrValues vanillaTweaks;
        infra.games.artifacts.games-minecraft-world-policy = policy;
        infra.games.artifacts.games-minecraft-grave-compass = graveCompass;
        infra.games.minecraftDatapacks.backends = lib.mapAttrs (id: s: {
          packs =
            vanillaTweaks
            // {
              world-policy = policy;
              grave-compass = graveCompass;
            }
            // lib.optionalAttrs s.minecraft.joinTips.enable { join-tips = joinTips id s; };
          inventory =
            map (pack: {
              inherit (pack) name version;
              installed = true;
            }) sources.packs
            ++ [
              {
                name = "Survival World Policy";
                version = "26.3 / 1";
                installed = true;
              }
              {
                name = "Grave Compass";
                version = "26.3 / 1";
                installed = true;
              }
            ]
            ++ lib.optional s.minecraft.joinTips.enable {
              name = "Survival Join Tips";
              version = "26.3 / 1";
              installed = true;
            };
        }) servers;
        infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
          statePaths = [ "/srv/games/minecraft/${id}/plugins/bStats" ];
          templates."/srv/games/minecraft/${id}/plugins/bStats/config.yml".source = toString (
            (pkgs.formats.yaml { }).generate "minecraft-bstats.yml" { enabled = false; }
          );
        }) servers;
        systemd.services = lib.mapAttrs' (
          id: _:
          lib.nameValuePair "minecraft-server-${id}" {
            serviceConfig.ExecStartPre = lib.mkOrder 1600 [
              # Run as the unit's Minecraft user, after prechange and games-prepare.
              "${installer} install ${
                pkgs.writeText "minecraft-${id}-datapacks.json" (
                  builtins.toJSON {
                    directory = "/srv/games/minecraft/${id}/world/datapacks";
                    packs = cfg.minecraftDatapacks.backends.${id}.packs;
                  }
                )
              }"
            ];
          }
        ) servers;
      };
    };
}

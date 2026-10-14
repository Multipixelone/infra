{ config, lib, ... }:
let
  host = config.flake.nixosConfigurations.link;
  cfg = host.config;
  runtime = cfg.infra.games.runtime.survival;
  packs = cfg.infra.games.minecraftDatapacks.backends.survival;
  modified =
    (host.extendModules {
      modules = [
        {
          infra.games.minecraftDatapacks.backends.survival.packs.world-policy = lib.mkForce (
            cfg.infra.games.artifacts.games-chunky
          );
        }
      ];
    }).config;
  fixture = {
    inherit (runtime) worldPaths fingerprint;
    modifiedFingerprint = modified.infra.games.runtime.survival.fingerprint;
    properties = runtime.configTemplates."/srv/games/minecraft/survival/server.properties".source;
    preStart = cfg.systemd.services.minecraft-server-survival.serviceConfig.ExecStartPre;
    user = cfg.systemd.services.minecraft-server-survival.serviceConfig.User;
    manifest = builtins.fromJSON cfg.environment.etc."games/manifest.json".text;
    chunky = cfg.infra.games.minecraftPlugins.backends.survival;
    sources = builtins.fromJSON (builtins.readFile ./datapacks/sources.json);
    retainedInputs = map toString cfg.system.extraDependencies;
    metadataFiles = builtins.attrNames (builtins.readDir ./datapacks);
    serverVersion = cfg.infra.games.servers.survival.minecraft.version;
    inherit packs;
  };
in
{
  perSystem = { pkgs, ... }: {
    checks.games-minecraft-world =
      let
        # Paper's META-INF/download-context pins these exact bootstrap bytes.
        # Preseed its cache so the temporary parser check needs no network.
        vanillaServer = pkgs.fetchurl {
          name = "minecraft-server-26.3.jar";
          url = "https://piston-data.mojang.com/v1/objects/33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c/server.jar";
          sha256 = "d052f14d7a173734fba553711e5b570162e2f2a313267ee31a21b975a679be64";
        };
      in
      pkgs.runCommand "games-minecraft-world-check"
        {
          nativeBuildInputs = [
            (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
            pkgs.jdk25_headless
          ];
        }
        ''
          export PYTHONDONTWRITEBYTECODE=1
          python3 ${./tests/minecraft_datapacks_test.py} ${./minecraft-datapacks.py}
          python3 ${./tests/minecraft_world_test.py} \
            ${pkgs.writeText "minecraft-world-fixture.json" (builtins.toJSON fixture)} \
            ${cfg.infra.games.artifacts.games-chunky}
          python3 ${./tests/minecraft_grave_compass_test.py} \
            ${packs.packs.grave-compass} \
            ${cfg.infra.games.artifacts.games-paper-survival}/lib/minecraft/server.jar \
            ${vanillaServer}
          touch "$out"
        '';
  };
}

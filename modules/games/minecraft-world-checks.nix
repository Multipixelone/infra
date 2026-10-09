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
    inherit packs;
  };
in
{
  perSystem = { pkgs, ... }: {
    checks.games-minecraft-world =
      pkgs.runCommand "games-minecraft-world-check"
        {
          nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ];
        }
        ''
          export PYTHONDONTWRITEBYTECODE=1
          python3 ${./tests/minecraft_datapacks_test.py} ${./minecraft-datapacks.py}
          python3 ${./tests/minecraft_world_test.py} \
            ${pkgs.writeText "minecraft-world-fixture.json" (builtins.toJSON fixture)} \
            ${cfg.infra.games.artifacts.games-chunky}
          touch "$out"
        '';
  };
}

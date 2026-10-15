{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      # Retain the pinned release's tree definitions and structure detection.
      configuration =
        pkgs.runCommand "treefeller-1.32.1-config.yml"
          { nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ]; }
          ''
            python3 - ${cfg.artifacts.games-treefeller} "$out" <<'PY'
            import pathlib, sys, zipfile
            import yaml
            with zipfile.ZipFile(sys.argv[1]) as jar:
                settings = yaml.safe_load(jar.read("config.yml"))
            settings.update({
                "startup-logs": False,
                "with-sneak": True,
                "without-sneak": False,
                "log-behavior": "FALL_NATURAL_BREAK",
                "directional-fall-behavior": "AWAY",
                "replant-saplings": True,
                "use-tree-saplings": True,
                "use-inventory-saplings": False,
                "spawn-saplings": 0,
                "respect-unbreaking": True,
                "damage-mult": 1.0,
                "allow-partial-tool": False,
                "allow-partial": False,
                "cascade": False,
                "cooldown": 20,
            })
            pathlib.Path(sys.argv[2]).write_text(yaml.safe_dump(settings, sort_keys=False))
            PY
          '';
    in
    lib.mkIf (servers != { }) {
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars.treefeller = cfg.artifacts.games-treefeller;
        templates."/srv/games/minecraft/${id}/plugins/TreeFeller/config.yml".source =
          toString configuration;
        statePaths = [ "/srv/games/minecraft/${id}/plugins/TreeFeller" ];
        inventory = [
          {
            name = "TreeFeller";
            version = "1.32.1";
            installed = true;
          }
        ];
      }) servers;
    };
}

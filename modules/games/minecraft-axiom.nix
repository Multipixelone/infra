{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      overrides = (pkgs.formats.json { }).generate "axiom-overrides.json" {
        whitelist-world-regex = "^world$";
        blueprint-sharing = false;
        allow-annotations = false;
        allow-large-chunk-data-request = false;
        allow-large-payload-for-all-packets = false;
        allow-teleport-between-worlds = false;
        # Sections per second, not blocks: each section contains 4096 blocks.
        block-buffer-rate-limit = 2;
        max-chunk-sends-per-tick = 2;
        max-chunk-relights-per-tick = 2;
        max-chunk-load-distance = 0;
        disallowed-blocks = map (name: "minecraft:${name}") [
          "bedrock"
          "barrier"
          "command_block"
          "chain_command_block"
          "repeating_command_block"
          "structure_block"
          "structure_void"
          "jigsaw"
          "spawner"
          "trial_spawner"
          "end_portal_frame"
          "end_portal"
          "end_gateway"
          "nether_portal"
          "light"
          "reinforced_deepslate"
          "moving_piston"
          "piston_head"
          "test_block"
          "test_instance_block"
        ];
      };
      # Axiom checks its complete config schema at startup. Preserve the pinned
      # defaults rather than generating an incomplete file or invented keys.
      # This release contains no updater/check-for-updates implementation.
      configuration =
        pkgs.runCommand "axiom-6.0.1-config.yml"
          { nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ]; }
          ''
            python3 - ${cfg.artifacts.games-axiom} ${overrides} "$out" <<'PY'
            import json, pathlib, sys, zipfile
            import yaml
            with zipfile.ZipFile(sys.argv[1]) as jar:
                configuration = yaml.safe_load(jar.read("config.yml"))
            overrides = json.loads(pathlib.Path(sys.argv[2]).read_text())
            assert overrides.keys() <= configuration.keys()
            configuration.update(overrides)
            pathlib.Path(sys.argv[3]).write_text(yaml.safe_dump(configuration, sort_keys=False))
            PY
          '';
    in
    lib.mkIf (servers != { }) {
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars.axiom = cfg.artifacts.games-axiom;
        # The descriptor calls the plugin AxiomPaper. Its data folder is linked
        # below to the managed Axiom directory so this config is actually read.
        templates."/srv/games/minecraft/${id}/plugins/Axiom/config.yml".source = toString configuration;
        statePaths = [ "/srv/games/minecraft/${id}/plugins/Axiom" ];
        inventory = [
          {
            name = "AxiomPaper";
            version = "6.0.1+26.3";
            installed = true;
          }
        ];
      }) servers;
      services.minecraft-servers.servers = lib.mapAttrs (id: _: {
        symlinks."plugins/AxiomPaper" = "/srv/games/minecraft/${id}/plugins/Axiom";
      }) servers;
    };
}

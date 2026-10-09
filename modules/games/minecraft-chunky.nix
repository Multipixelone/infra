{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      configuration = (pkgs.formats.yaml { }).generate "chunky-1.5.3.yml" {
        version = 2;
        language = "en";
        continue-on-restart = false;
        force-load-existing-chunks = false;
        silent = false;
        update-interval = 1;
      };
    in
    lib.mkIf (servers != { }) {
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars.chunky = cfg.artifacts.games-chunky;
        templates."/srv/games/minecraft/${id}/plugins/Chunky/config.yml".source = toString configuration;
        statePaths = [ "/srv/games/minecraft/${id}/plugins/Chunky" ];
        inventory = [
          {
            name = "Chunky";
            version = "1.5.3";
            installed = true;
          }
        ];
      }) servers;
      # No verified Paper 26.3 ChunkyBorder release: do not install a 26.2 JAR.
      # Neither configuration nor any startup hook starts a generation task.
    };
}

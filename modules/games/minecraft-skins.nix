{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      jar = cfg.artifacts.games-skinsrestorer;
      templates = dir: {
        "${dir}/config.yml".source = toString (
          (pkgs.formats.yaml { }).generate "skinsrestorer.yml" {
            server.proxyMode = {
              detection = "AUTO";
              api = false;
            };
            database.enabled = false;
            api.fetchRecommendedSkins = false;
          }
        );
        # Upstream's supported opt-out; a YAML key does not disable its downloader.
        "${dir}/noautoupdate.txt".source = toString (
          pkgs.writeText "skinsrestorer-noautoupdate" "Managed by Nix\n"
        );
      };
    in
    lib.mkIf (servers != { }) {
      infra.games.minecraftPlugins = {
        proxy = {
          jars.skinsrestorer = jar;
          templates = templates "/srv/games/minecraft/velocity/plugins/skinsrestorer";
          inventory = [
            {
              name = "SkinsRestorer";
              version = "15.12.6";
              installed = true;
            }
          ];
        };
        backends = lib.mapAttrs (id: _: {
          jars.skinsrestorer = jar;
          templates = templates "/srv/games/minecraft/${id}/plugins/SkinsRestorer";
          statePaths = [ "/srv/games/minecraft/${id}/plugins/SkinsRestorer" ];
          inventory = [
            {
              name = "SkinsRestorer";
              version = "15.12.6";
              installed = true;
            }
          ];
        }) servers;
      };
      infra.backup.srvPaths = [ "/srv/games/minecraft/velocity/plugins/skinsrestorer" ];
    };
}

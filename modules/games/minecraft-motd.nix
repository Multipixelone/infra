{ lib, ... }:
{
  flake.modules.nixos.games-minecraft = { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      format = pkgs.formats.hocon {};
      dir = "/srv/games/minecraft/velocity/plugins/minimotd-velocity";
    in lib.mkIf (servers != {}) {
      infra.games.minecraftPlugins.proxy = {
        jars.minimotd = cfg.artifacts.games-minimotd;
        inventory = [{ name = "MiniMOTD"; version = "2.2.5"; installed = true; }];
        templates = {
          "${dir}/main.conf".source = toString (format.generate "minimotd-main.conf" {
            motd-enabled = true;
            icon-enabled = false;
            motds = [{
              line1 = "<gradient:#ff9e42:#ffb366><bold>Finn's Survival</bold></gradient>";
              line2 = "<gradient:#9e9486:#e8e2d8>A quiet place to build & explore</gradient>";
            }];
            player-count-settings = {
              max-players-enabled = false;
              fake-players.fake-players-enabled = false;
              just-x-more-settings.just-x-more-enabled = false;
            };
          });
          "${dir}/plugin_settings.conf".source = toString (format.generate "minimotd-settings.conf" {
            update-checker = false;
            proxy-settings.virtual-host-test-mode = false;
          });
          "/srv/games/minecraft/velocity/plugins/bStats/config.txt".source = toString ((pkgs.formats.javaProperties {}).generate "bstats.properties" { enabled = false; });
        };
      };
    };
}

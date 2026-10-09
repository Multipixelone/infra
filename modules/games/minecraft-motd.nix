{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      format = pkgs.formats.hocon { };
      dir = "/srv/games/minecraft/velocity/plugins/minimotd-velocity";
      icon = pkgs.runCommand "survival-server-icon" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
        mkdir -p "$out"
        magick ${./assets/survival-icon-source.png} \
          -filter box -resize 24x24 +dither -posterize 4 \
          -sampling-factor 4:2:0 -quality 18 crushed.jpg
        magick crushed.jpg -filter point -resize 64x64 -strip -depth 8 \
          PNG24:"$out/server-icon.png"
        test "$(magick identify -format '%m %wx%h' "$out/server-icon.png")" = "PNG 64x64"
      '';
    in
    lib.mkIf (servers != { }) {
      services.minecraft-servers.servers.velocity.symlinks = {
        "plugins/minimotd-velocity/icons/survival.png" = "${icon}/server-icon.png";
        "server-icon.png" = "${icon}/server-icon.png";
      };
      infra.games.minecraftPlugins.proxy = {
        jars.minimotd = cfg.artifacts.games-minimotd;
        inventory = [
          {
            name = "MiniMOTD";
            version = "2.2.5";
            installed = true;
          }
        ];
        templates = {
          "${dir}/main.conf".source = toString (
            format.generate "minimotd-main.conf" {
              motd-enabled = true;
              icon-enabled = true;
              motds = [
                {
                  # Mocha mauve/peach: Stylix's scheme; pink/subtext0: Foot's Mocha palette.
                  line1 = "<gradient:#cba6f7:#f5c2e7:#fab387><bold>Finn's Survival</bold></gradient>";
                  line2 = "<#a6adc8><#cba6f7>mc.finnrut.is</#cba6f7> · survival · 26.3</#a6adc8>";
                  icon = "survival";
                }
              ];
              player-count-settings = {
                max-players-enabled = false;
                fake-players.fake-players-enabled = false;
                just-x-more-settings.just-x-more-enabled = false;
              };
            }
          );
          "${dir}/plugin_settings.conf".source = toString (
            format.generate "minimotd-settings.conf" {
              update-checker = false;
              proxy-settings.virtual-host-test-mode = false;
            }
          );
          "/srv/games/minecraft/velocity/plugins/bStats/config.txt".source = toString (
            (pkgs.formats.javaProperties { }).generate "bstats.properties" { enabled = "false"; }
          );
        };
      };
    };
}

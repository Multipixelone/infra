{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      configuration = (pkgs.formats.yaml { }).generate "doubledoors-1.4.9.yml" {
        serverWideEnabled = true;
        enableDoors = true;
        # Despite its name, this also gates ordinary paired-door clicks in 1.4.9.
        # Gates/trapdoors remain disabled separately below.
        enableRecursiveOpening = true;
        enableFenceGates = false;
        enableTrapdoors = false;
        enableAutoClose = false;
        enableKnockFeature = false;
        enablePartnerParticles = false;
        interactionCooldownMillis = 250;
        enableAnonymousTracking = false;
        sql.enabled = false;
        updateChecker = {
          enabled = false;
          notify = false;
        };
      };
    in
    lib.mkIf (servers != { }) {
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars.doubledoors = cfg.artifacts.games-doubledoors;
        templates."/srv/games/minecraft/${id}/plugins/DoubleDoors/config.yml".source =
          toString configuration;
        statePaths = [ "/srv/games/minecraft/${id}/plugins/DoubleDoors" ];
        inventory = [
          {
            name = "DoubleDoors";
            version = "1.4.9";
            installed = true;
          }
        ];
      }) servers;
    };
}

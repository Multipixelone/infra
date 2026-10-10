{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      offlineConfig = (pkgs.formats.yaml { }).generate "bluemap-offline-player-markers-3.3.yml" {
        MarkerSetName = "Offline Players";
        Toggleable = true;
        DefaultHidden = false;
        ExpireTimeInHours = 0;
        HiddenGameModes = [ "spectator" ];
        HideBannedPlayers = true;
      };
    in
    lib.mkIf (servers != { }) {
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars = {
          bluemap-floodgate = cfg.artifacts.games-bluemap-floodgate;
          bluemap-offline-markers = cfg.artifacts.games-bluemap-offline-markers;
        };
        templates."/srv/games/minecraft/${id}/plugins/BlueMapOfflinePlayerMarkers/config.yml".source =
          toString offlineConfig;
        statePaths = map (name: "/srv/games/minecraft/${id}/plugins/${name}") [
          "BlueMapFloodgate"
          "BlueMapOfflinePlayerMarkers"
        ];
        inventory = [
          {
            name = "BlueMapFloodgate";
            version = "3.6";
            installed = true;
          }
          {
            name = "BlueMapOfflinePlayerMarkers";
            version = "3.3";
            installed = true;
          }
        ];
      }) servers;
      # Both jars shade UpdateChecker 2.5.1. Pin updates declaratively and
      # prevent its GitHub request from delaying/failing plugin enablement.
      systemd.services = lib.mapAttrs' (
        id: _:
        lib.nameValuePair "minecraft-server-${id}" {
          environment.JAVA_TOOL_OPTIONS = "-Dtechnicjelle.updatechecker.disabled";
        }
      ) servers;
    };
}

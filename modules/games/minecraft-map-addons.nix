{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
    in
    lib.mkIf (servers != { }) {
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars = {
          bluemap-floodgate = cfg.artifacts.games-bluemap-floodgate;
        };
        statePaths = map (name: "/srv/games/minecraft/${id}/plugins/${name}") [
          "BlueMapFloodgate"
        ];
        inventory = [
          {
            name = "BlueMapFloodgate";
            version = "3.6";
            installed = true;
          }
        ];
      }) servers;
      # The jar shades UpdateChecker 2.5.1. Pin updates declaratively and
      # prevent its GitHub request from delaying/failing plugin enablement.
      systemd.services = lib.mapAttrs' (
        id: _:
        lib.nameValuePair "minecraft-server-${id}" {
          environment.JAVA_TOOL_OPTIONS = "-Dtechnicjelle.updatechecker.disabled";
        }
      ) servers;
    };
}

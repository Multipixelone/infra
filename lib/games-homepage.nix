{ lib }:
{
  tiles =
    servers: dashboardUrl:
    map (server: {
      ${server.displayName} =
        if server.game == "minecraft-paper" then
          {
            icon = "minecraft";
            description = "${lib.concatStringsSep ", " server.hostnames} · sleeps when idle; Up includes sleeping";
            widget = {
              type = "minecraft";
              # Homepage's URL convention says udp, but its Minecraft handler
              # sends Java status requests over TCP. Never query Paper here.
              url = "udp://127.0.0.1:${toString server.minecraft.proxyPort}";
              fields = [
                "players"
                "version"
                "status"
              ];
            };
          }
        else
          {
            icon = "terraria";
            description = "${
              lib.concatStringsSep ", " (map (host: "${host}:${toString server.terraria.port}") server.hostnames)
            } · tModLoader";
            widget = {
              type = "customapi";
              url = "http://127.0.0.1:18777/servers/${server.id}";
              refreshInterval = 10000;
              mappings = [
                {
                  field = "status";
                  format = "text";
                  label = "TCP status";
                }
              ];
            };
          };
    }) (lib.sortOn (server: server.displayName) (lib.attrValues servers))
    ++ [
      {
        "Games dashboard" = {
          href = dashboardUrl;
          description = "Games management";
          icon = "mdi-controller";
        };
      }
    ];

  # Publication may also contribute this URL once its separate change lands.
  # Move that tile here and consolidate Games without disturbing other groups.
  appendGroups =
    groups: tiles: dashboardUrl:
    let
      clean = map (
        group:
        lib.mapAttrs (
          _: entries:
          builtins.filter (
            entry: lib.all (tile: (tile.href or null) != dashboardUrl) (lib.attrValues entry)
          ) entries
        ) group
      ) groups;
      existingGames = lib.concatMap (group: group.Games or [ ]) clean;
      others = lib.filter (group: group != { }) (
        map (group: lib.filterAttrs (name: entries: name != "Games" && entries != [ ]) group) clean
      );
    in
    others ++ [ { Games = existingGames ++ tiles; } ];
}

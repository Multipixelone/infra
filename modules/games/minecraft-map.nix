{ lib, ... }:
{
  servicePublication.applications.minecraft-map = {
    site = "nyc";
    public = true;
    publicHostname = "map.finnrut.is";
    access = {
      bypassAccess = true;
      bypassJustification = "Finn approved a public read-only Minecraft world map; viewing static map tiles requires no Access identity.";
    };
    homepage = {
      name = "Survival Map";
      group = "Games";
      description = "Finn's survival world";
      icon = "mdi-map";
    };
    routes.root = {
      backend = {
        host = "link";
        port = 8766;
      };
      proxy.host = "link";
      health = {
        path = "/index.html";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 8;
      };
    };
    nginx.extraConfig = ''
      client_max_body_size 1k;
      if ($request_method !~ ^(GET|HEAD)$) { return 405; }
    '';
  };
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      dir = id: "/srv/games/minecraft/${id}/plugins/BlueMap";
      format = pkgs.formats.hocon { };
      flowMath = pkgs.fetchurl {
        url = "https://repo.maven.apache.org/maven2/com/flowpowered/flow-math/1.0.3/flow-math-1.0.3.jar";
        sha256 = "dea201031f7660ebcc76041365d78d74b9bfb36faec70d3ea0dcfc503d3dc674";
      };
      bundled = pkgs.runCommand "bluemap-5.28-offline.jar" { } ''
        ${pkgs.python3}/bin/python3 ${./bundle-bluemap.py} ${cfg.artifacts.games-bluemap} ${flowMath} "$out"
      '';
    in
    lib.mkIf (servers != { }) {
      infra.games.artifacts.games-bluemap-offline = bundled;
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars.bluemap = bundled;
        inventory = [
          {
            name = "BlueMap";
            version = "5.28";
            installed = true;
          }
        ];
        statePaths = [ (dir id) ];
        templates =
          lib.mapAttrs'
            (
              name: value:
              lib.nameValuePair "${dir id}/${name}.conf" {
                source = toString (format.generate "bluemap-${id}-${name}.conf" value);
              }
            )
            {
              core = {
                accept-download = false;
                data = "${dir id}/data";
                render-thread-count = 1;
                render-thread-priority = 1;
                update-cooldown = 60;
                full-update-interval = 1440;
                scan-for-mod-resources = false;
                metrics = false;
              };
              webapp = {
                enabled = true;
                webroot = "${dir id}/web";
                client-decompression = true;
              };
              webserver.enabled = false;
              plugin = {
                live-player-markers = false;
                # HuskHomes publishes public home/warp marker sets. Keep those
                # responsive on the static webroot without publishing players.
                write-markers-interval = 30;
                write-players-interval = 0;
                skin-download = false;
                player-render-limit = 1;
              };
              "storages/file" = {
                storage-type = "file";
                root = "${dir id}/web/maps";
                compression = "gzip";
              };
            };
      }) servers;
      # BlueMap otherwise downloads its vanilla assets at first wake.
      services.minecraft-servers.servers = lib.mapAttrs (id: _: {
        symlinks."plugins/BlueMap/data/minecraft-client-26.3.jar" = cfg.artifacts.games-minecraft-client;
      }) servers;
      users.groups.minecraft-map = { };
      users.users.nginx.extraGroups = [ "minecraft-map" ];
      systemd.tmpfiles.rules = lib.concatMap (
        id:
        [
          "d /srv/games/minecraft/${id}/plugins 0750 minecraft minecraft -"
          "d ${dir id} 0750 minecraft minecraft -"
          "d ${dir id}/web 2750 minecraft minecraft-map -"
          "a+ ${dir id}/web - - - - d:g:minecraft-map:r-x"
        ]
        ++ map (path: "a+ ${path} - - - - g:minecraft-map:--x") [
          "/srv/games/minecraft"
          "/srv/games/minecraft/${id}"
          "/srv/games/minecraft/${id}/plugins"
          (dir id)
        ]
      ) (lib.attrNames servers);
      services.nginx.virtualHosts.minecraft-map-origin = {
        listen = [
          {
            addr = "127.0.0.1";
            port = 8766;
          }
        ];
        root = "${dir cfg.defaultServer}/web";
        extraConfig = ''
          autoindex off;
          client_max_body_size 1k;
          if ($request_method !~ ^(GET|HEAD)$) { return 405; }
          add_header X-Content-Type-Options nosniff always;
          add_header Referrer-Policy no-referrer always;
        '';
        locations."/".tryFiles = "$uri $uri/ =404";
        locations."~ /\\.".extraConfig = "deny all;";
      };
    };
}

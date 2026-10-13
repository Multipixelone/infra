{ lib, ... }:
{
  servicePublication.applications.minecraft-map = {
    site = "nyc";
    public = true;
    publicHostname = "map.finnrut.is";
    access = {
      bypassAccess = true;
      bypassJustification = "Finn approved a public read-only Minecraft world map, including normally visible players' names and locations; viewing requires no Access identity.";
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
      securityHeaders = ''
        add_header X-Content-Type-Options nosniff always;
        add_header Referrer-Policy no-referrer always;
      '';
      # Compose only shared tokens and BlueMap chrome, never Homepage layout.
      theme = pkgs.writeText "bluemap-homepage-theme.css" (
        builtins.readFile ../link/homepage-theme-tokens.css + "\n" + builtins.readFile ./bluemap-theme.css
      );
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
                # BlueMap 5.28 publishes these URLs in settings.json; the client
                # appends stylesheet links. nginx serves the persisted webroot.
                styles = [ "css/homepage-theme.css" ];
              };
              webserver.enabled = false;
              plugin = {
                # This switch controls the embedded server's live supplier.
                # Static nginx uses the independently scheduled player writer.
                live-player-markers = false;
                hidden-game-modes = [ "spectator" ];
                hide-vanished = true;
                hide-invisible = true;
                # Keep public homes/warps and player JSON current while awake.
                write-markers-interval = 30;
                write-players-interval = 3;
                skin-download = true;
                player-render-limit = 1;
              };
              "storages/file" = {
                storage-type = "file";
                root = "${dir id}/web/maps";
                compression = "gzip";
              };
            }
          // {
            "${dir id}/web/css/homepage-theme.css" = {
              source = toString theme;
              # Config templates default to 0600. This public asset needs the
              # webroot's minecraft-map ACL to remain effective for nginx.
              mode = "0644";
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
          ${securityHeaders}
        '';
        locations."/".tryFiles = "$uri $uri/ =404";
        locations."~ /\\.".extraConfig = "deny all;";
        locations."~ ^/maps/[^/]+/live/players\\.json$" = {
          tryFiles = "$uri =404";
          extraConfig = ''
            add_header Cache-Control no-store always;
            # Location headers replace inherited ones in nginx.
            ${securityHeaders}
          '';
        };
      };
    };
}

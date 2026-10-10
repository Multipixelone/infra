{ config, lib, ... }:
let
  host = config.flake.nixosConfigurations.link;
  cfg = host.config;
  project =
    c:
    lib.mapAttrs (id: _: {
      templates = lib.filterAttrs (
        path: _: lib.hasInfix "/plugins/BlueMap/" path
      ) c.infra.games.minecraftPlugins.backends.${id}.templates;
      runtimeTemplates = lib.filterAttrs (
        path: _: lib.hasInfix "/plugins/BlueMap/" path
      ) c.infra.games.runtime.${id}.configTemplates;
    }) (lib.filterAttrs (_: s: s.game == "minecraft-paper") c.infra.games.servers);
  additional =
    (host.extendModules {
      modules = [
        {
          infra.games.secretFiles = lib.mkForce { };
          infra.games.servers.testing = cfg.infra.games.servers.survival // {
            minecraft = cfg.infra.games.servers.survival.minecraft // {
              serverPort = 25575;
              proxyPort = 25576;
              rconPort = 25577;
            };
          };
        }
      ];
    }).config;
  without =
    (host.extendModules {
      modules = [ { infra.games.servers = lib.mkForce { }; } ];
    }).config;
  vhost = cfg.services.nginx.virtualHosts.minecraft-map-origin;
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.games-minecraft-map =
        pkgs.runCommand "games-minecraft-map-check"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.nginx
              pkgs.jdk25_headless
            ];
          }
          ''
            python3 ${./tests/minecraft_map_test.py} \
              ${
                pkgs.writeText "minecraft-map-fixtures.json" (
                  builtins.toJSON {
                    production = project cfg;
                    additional = project additional;
                    without = without.infra.games.minecraftPlugins.backends;
                    homepageCSS = cfg.services.homepage-dashboard.customCSS;
                    inherit (vhost) root;
                  }
                )
              } \
              ${cfg.infra.games.artifacts.games-bluemap-offline} \
              ${./tests/ReadBlueMapWebSettings.java} \
              ${../link/homepage-theme-tokens.css} \
              ${pkgs.writeText "minecraft-map-nginx.conf" ''
                pid @ROOT@/nginx.pid;
                error_log stderr;
                events {}
                http {
                  include ${pkgs.nginx}/conf/mime.types;
                  access_log off;
                  client_body_temp_path @ROOT@/body;
                  server {
                    listen 127.0.0.1:@PORT@;
                    root @ROOT@/web;
                    ${vhost.extraConfig}
                    location / { try_files ${vhost.locations."/".tryFiles}; }
                    location ~ /\. { deny all; }
                  }
                }
              ''} \
              ${cfg.infra.games.artifacts.games-paper-survival}/lib/minecraft/server.jar \
              ${
                # Vanilla supplies Gson; Paper's pinned libraries.list records
                # its exact hash, but does not embed it in the server bundle.
                pkgs.fetchurl {
                  url = "https://repo.maven.apache.org/maven2/com/google/code/gson/gson/2.14.0/gson-2.14.0.jar";
                  sha256 = "2cbd119bf1961c28788310963dc80ba65f58cdeec1dd139c8bdb1240faa2c36f";
                }
              }
            touch "$out"
          '';
    };
}

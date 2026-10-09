{ config, lib, ... }:
let
  host = config.flake.nixosConfigurations.link;
  base = host.config.infra.games.servers;
  evaluate =
    secrets: guild: channel: enabled:
    (host.extendModules {
      modules = [
        {
          infra.games.secretFiles = lib.mkForce secrets;
          infra.games.servers = lib.mkForce (
            base
            // {
              survival = base.survival // {
                minecraft = base.survival.minecraft // {
                  discord = {
                    enable = enabled;
                    guildId = guild;
                    channelId = channel;
                  };
                };
              };
            }
          );
        }
      ];
    }).config;
  fixtures =
    map
      (
        case:
        let
          cfg = evaluate (lib.optionalAttrs case.token {
            "games/minecraft/discordsrv-token" = ./tests/fixture.age;
          }) case.guild case.channel case.enable;
          plugins = cfg.infra.games.minecraftPlugins.backends.survival;
          runtime = cfg.infra.games.runtime.survival;
        in
        {
          expected = case.token && case.guild != "" && case.channel != "" && case.enable;
          installed = plugins.jars ? discordsrv;
          tokenCopy = plugins.templates."/srv/games/minecraft/survival/plugins/DiscordSRV/.token" or null;
          declaredSecret = cfg.age.secrets."games/minecraft/discordsrv-token".mode or null;
          baseAvailable = runtime.available;
          statePaths = runtime.worldPaths;
        }
      )
      [
        {
          token = false;
          guild = "123456789012345678";
          channel = "234567890123456789";
          enable = true;
        }
        {
          token = true;
          guild = "";
          channel = "";
          enable = true;
        }
        {
          token = true;
          guild = "123456789012345678";
          channel = "";
          enable = true;
        }
        {
          token = true;
          guild = "";
          channel = "234567890123456789";
          enable = true;
        }
        {
          token = true;
          guild = "123456789012345678";
          channel = "234567890123456789";
          enable = false;
        }
        {
          token = true;
          guild = "123456789012345678";
          channel = "234567890123456789";
          enable = true;
        }
      ];
  cfg = host.config;
  vhost = cfg.services.nginx.virtualHosts.minecraft-map-origin;
in
{
  perSystem = { pkgs, ... }: {
    checks.games-minecraft-plugins =
      pkgs.runCommand "games-minecraft-plugins-check"
        {
          nativeBuildInputs = [
            pkgs.python3
            pkgs.nginx
          ];
        }
        ''
          python3 ${./tests/minecraft_plugins_test.py} \
            ${pkgs.writeText "minecraft-plugin-fixtures.json" (builtins.toJSON fixtures)} \
            ${pkgs.writeText "minecraft-static-nginx.conf" ''
              pid @ROOT@/nginx.pid;
              error_log stderr;
              events {}
              http {
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
            ${cfg.infra.games.artifacts.games-bluemap-offline} \
            ${cfg.infra.games.artifacts.games-luckperms-libraries}
          touch "$out"
        '';
  };
}

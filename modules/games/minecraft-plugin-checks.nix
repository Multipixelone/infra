{ config, lib, ... }:
let
  host = config.flake.nixosConfigurations.link;
  base = host.config.infra.games.servers;
  evaluate =
    secrets: guild: channel: enabled: overrides:
    (host.extendModules {
      modules = [
        {
          infra.games.secretFiles = lib.mkForce secrets;
          infra.games.servers = lib.mkForce (
            base
            // {
              survival = base.survival // {
                minecraft = base.survival.minecraft // {
                  discord =
                    base.survival.minecraft.discord
                    // {
                      enable = enabled;
                      guildId = guild;
                      channelId = channel;
                    }
                    // overrides;
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
          }) case.guild case.channel case.enable (case.overrides or { });
          plugins = cfg.infra.games.minecraftPlugins.backends.survival;
          runtime = cfg.infra.games.runtime.survival;
        in
        {
          expected = case.token && case.guild != "" && case.channel != "" && case.enable;
          installed = plugins.jars ? discordsrv;
          vaultInstalled = plugins.jars ? vault;
          vaultConfiguration =
            plugins.templates."/srv/games/minecraft/survival/plugins/Vault/config.yml".source or null;
          tokenCopy = plugins.templates."/srv/games/minecraft/survival/plugins/DiscordSRV/.token" or null;
          preStart = cfg.systemd.services.minecraft-server-survival.serviceConfig.ExecStartPre;
          declaredSecret = cfg.age.secrets."games/minecraft/discordsrv-token".mode or null;
          baseAvailable = runtime.available;
          statePaths = runtime.worldPaths;
          discord = cfg.infra.games.servers.survival.minecraft.discord;
          configuration =
            plugins.templates."/srv/games/minecraft/survival/plugins/DiscordSRV/config.yml".source or null;
          messages =
            plugins.templates."/srv/games/minecraft/survival/plugins/DiscordSRV/messages.yml".source or null;
          synchronization =
            plugins.templates."/srv/games/minecraft/survival/plugins/DiscordSRV/synchronization.yml".source
              or null;
          linking =
            plugins.templates."/srv/games/minecraft/survival/plugins/DiscordSRV/linking.yml".source or null;
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
        {
          token = true;
          guild = "123456789012345678";
          channel = "234567890123456789";
          enable = true;
          overrides.roles = {
            mod = "";
            admin = "";
          };
        }
        {
          token = true;
          guild = "123456789012345678";
          channel = "234567890123456789";
          enable = true;
          overrides.roles = {
            mod = "345678901234567890";
            admin = "";
          };
        }
        {
          token = true;
          guild = "123456789012345678";
          channel = "234567890123456789";
          enable = true;
          overrides.roles = {
            mod = "";
            admin = "456789012345678901";
          };
        }
        {
          token = true;
          guild = "123456789012345678";
          channel = "234567890123456789";
          enable = true;
          overrides.eventsChannelId = "";
        }
        {
          token = true;
          guild = "123456789012345678";
          channel = "234567890123456789";
          enable = true;
          overrides.consoleChannelId = "";
        }
      ];
  cfg = host.config;
  vhost = cfg.services.nginx.virtualHosts.minecraft-map-origin;
  permissions = evaluate {
    "games/minecraft/luckperms-db-password" = ./tests/fixture.age;
  } "" "" true { };
  permissionsFixture = {
    proxyInstalled = permissions.infra.games.minecraftPlugins.proxy.jars ? luckperms;
    backendInstalled = permissions.infra.games.minecraftPlugins.backends.survival.jars ? luckperms;
    baseAvailable = permissions.infra.games.runtime.survival.available;
    databases = permissions.services.postgresql.ensureDatabases;
    role = lib.findFirst (
      user: user.name == "luckperms"
    ) null permissions.services.postgresql.ensureUsers;
    authentication = permissions.services.postgresql.authentication;
    secret = lib.getAttrs [
      "owner"
      "group"
      "mode"
    ] permissions.age.secrets."games/minecraft/luckperms-db-password";
    provision =
      lib.getAttrs [
        "User"
        "LoadCredential"
      ] permissions.systemd.services.luckperms-provision.serviceConfig
      // lib.getAttrs [
        "after"
        "requires"
      ] permissions.systemd.services.luckperms-provision;
    backendTemplates = lib.filterAttrs (
      path: _: lib.hasInfix "/plugins/LuckPerms/" path
    ) permissions.infra.games.minecraftPlugins.backends.survival.templates;
    proxyTemplates = permissions.infra.games.minecraftPlugins.proxy.templates;
  };
in
{
  perSystem = { pkgs, ... }: {
    checks.games-minecraft-plugins =
      pkgs.runCommand "games-minecraft-plugins-check"
        {
          nativeBuildInputs = [
            (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
            pkgs.nginx
          ];
        }
        ''
          python3 ${./tests/minecraft_discord_token_test.py} ${./minecraft-discord-token.py}
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
            ${cfg.infra.games.artifacts.games-luckperms-libraries} \
            ${pkgs.writeText "minecraft-permissions-fixture.json" (builtins.toJSON permissionsFixture)} \
            ${cfg.infra.games.artifacts.games-discordsrv}
          touch "$out"
        '';
  };
}

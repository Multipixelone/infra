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
            builder = "";
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
            builder = "567890123456789012";
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
  buildingNames = [
    "FastAsyncWorldEdit"
    "FastAsyncVoxelSniper"
    "WorldEditSelectionVisualizer"
  ];
  buildingFixture = {
    plugins = lib.mapAttrs (_: toString) (
      lib.getAttrs [
        "fawe"
        "voxelsniper"
        "worldedit-visualizer"
      ] cfg.infra.games.minecraftPlugins.backends.survival.jars
    );
    templates = lib.filterAttrs (
      path: _: lib.any (name: lib.hasInfix "/plugins/${name}/" path) buildingNames
    ) cfg.infra.games.minecraftPlugins.backends.survival.templates;
    statePaths = cfg.infra.games.runtime.survival.worldPaths;
    inventory = cfg.infra.games.runtime.survival.pluginInventory;
    symlinks = lib.mapAttrs (_: toString) (
      lib.filterAttrs (
        path: _:
        lib.elem path [
          "plugins/fawe.jar"
          "plugins/voxelsniper.jar"
          "plugins/worldedit-visualizer.jar"
        ]
      ) cfg.services.minecraft-servers.servers.survival.symlinks
    );
    proxyInventory = cfg.infra.games.minecraftPlugins.proxy.inventory;
    withoutBackends =
      (host.extendModules {
        modules = [ { infra.games.servers = lib.mkForce { }; } ];
      }).config.infra.games.minecraftPlugins.backends;
  };
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
  polishFixture = c: {
    backends = c.infra.games.minecraftPlugins.backends;
    proxyJars = lib.attrNames c.infra.games.minecraftPlugins.proxy.jars;
    servers = lib.mapAttrs (id: _: {
      inherit (c.infra.games.runtime.${id}) available worldPaths;
      environment = c.systemd.services."minecraft-server-${id}".environment;
      symlinks = c.services.minecraft-servers.servers.${id}.symlinks;
    }) (lib.filterAttrs (_: s: s.game == "minecraft-paper") c.infra.games.servers);
  };
  polishFixtures = {
    missingSecrets = polishFixture (evaluate { } "" "" false { });
    withLuckPerms = polishFixture permissions;
    withoutAdmin = polishFixture (
      (host.extendModules {
        modules = [
          {
            infra.games.secretFiles = lib.mkForce {
              "games/minecraft/luckperms-db-password" = ./tests/fixture.age;
            };
            infra.games.minecraftAdminUuid = lib.mkForce null;
          }
        ];
      }).config
    );
    withDiscord = polishFixture (
      evaluate {
        "games/minecraft/luckperms-db-password" = ./tests/fixture.age;
        "games/minecraft/discordsrv-token" = ./tests/fixture.age;
      } "123456789012345678" "234567890123456789" true { }
    );
    additionalBackend =
      polishFixture
        (host.extendModules {
          modules = [
            {
              infra.games.secretFiles = lib.mkForce {
                "games/minecraft/luckperms-db-password" = ./tests/fixture.age;
              };
              infra.games.servers = lib.mkForce (
                base
                // {
                  testing = base.survival // {
                    minecraft = base.survival.minecraft // {
                      serverPort = 25575;
                      proxyPort = 25576;
                      rconPort = 25577;
                    };
                  };
                }
              );
            }
          ];
        }).config;
    noPaper =
      polishFixture
        (host.extendModules {
          modules = [
            {
              infra.games.servers = lib.mkForce (lib.filterAttrs (_: s: s.game != "minecraft-paper") base);
            }
          ];
        }).config;
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
            pkgs.gzip
            pkgs.jdk25_headless
          ];
        }
        ''
          python3 ${./tests/minecraft_discord_token_test.py} ${./minecraft-discord-token.py}
          python3 ${./tests/minecraft_polish_test.py} \
            ${pkgs.writeText "minecraft-polish-fixtures.json" (builtins.toJSON polishFixtures)} \
            ${
              pkgs.writeText "minecraft-polish-artifacts.json" (
                builtins.toJSON {
                  openinv = cfg.infra.games.artifacts.games-openinv;
                  openinvCache = cfg.infra.games.artifacts.games-openinv-libraries;
                  carbon = cfg.infra.games.artifacts.games-carbon;
                  carbonCache = cfg.infra.games.artifacts.games-carbon-libraries;
                  miniplaceholders = cfg.infra.games.artifacts.games-miniplaceholders;
                  luckpermsExpansion = cfg.infra.games.artifacts.games-miniplaceholders-luckperms;
                  flectonepulse = cfg.infra.games.artifacts.games-flectonepulse;
                  flectonepulseCache = cfg.infra.games.artifacts.games-flectonepulse-libraries;
                  minecraftClient = cfg.infra.games.artifacts.games-minecraft-client;
                  paper = cfg.infra.games.artifacts.games-paper-survival;
                  luckperms = cfg.infra.games.artifacts.games-luckperms-paper;
                  discordsrv = cfg.infra.games.artifacts.games-discordsrv;
                  # Bukkit Plugin exposes Log4j Logger; Minecraft supplies this
                  # outside Paper's embedded plugin-test library bundle.
                  log4jApi = pkgs.fetchurl {
                    url = "https://repo.maven.apache.org/maven2/org/apache/logging/log4j/log4j-api/2.26.0/log4j-api-2.26.0.jar";
                    sha256 = "820de7bbaf430eaf2e3e5ccb92f23e2085797c5ac4d4f7fc6c8b660fbefa1dbc";
                  };
                }
              )
            } ${./tests}
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
            ${cfg.infra.games.artifacts.games-discordsrv} \
            ${pkgs.writeText "minecraft-building-fixture.json" (builtins.toJSON buildingFixture)} \
            ${
              pkgs.writeText "minecraft-map-fixture.json" (
                builtins.toJSON {
                  fixtures = polishFixtures;
                  floodgate = cfg.infra.games.artifacts.games-bluemap-floodgate;
                  offline = cfg.infra.games.artifacts.games-bluemap-offline-markers;
                  paper = cfg.infra.games.artifacts.games-paper-survival;
                  # Supplied by Minecraft rather than Paper's bootstrap bundle.
                  gson = pkgs.fetchurl {
                    url = "https://repo.maven.apache.org/maven2/com/google/code/gson/gson/2.14.0/gson-2.14.0.jar";
                    sha256 = "2cbd119bf1961c28788310963dc80ba65f58cdeec1dd139c8bdb1240faa2c36f";
                  };
                  guava = pkgs.fetchurl {
                    url = "https://repo.maven.apache.org/maven2/com/google/guava/guava/33.6.0-jre/guava-33.6.0-jre.jar";
                    sha256 = "dc573e1fca4fd5454f4a5fd3d7da2df03002876a4175bafc14a95980dd7713b3";
                  };
                  fastutil = pkgs.fetchurl {
                    url = "https://repo.maven.apache.org/maven2/it/unimi/dsi/fastutil/8.5.18/fastutil-8.5.18.jar";
                    sha256 = "9094ae67d01d0ad246f886f11ad557fc2e79c72cbf3feed83e1512a8ae90a74a";
                  };
                  examinationApi = pkgs.fetchurl {
                    url = "https://repo.maven.apache.org/maven2/net/kyori/examination-api/1.3.0/examination-api-1.3.0.jar";
                    sha256 = "c9237ffecb05428f6eff86216246ac70ce0b47b04c08ea7ca35020fde57f8492";
                  };
                  examinationString = pkgs.fetchurl {
                    url = "https://repo.maven.apache.org/maven2/net/kyori/examination-string/1.3.0/examination-string-1.3.0.jar";
                    sha256 = "7d01fc25a4bb3af0e1662685455f4541fbf4626216ea5846e455c1491e156b8c";
                  };
                }
              )
            } ${./tests}
          touch "$out"
        '';
  };
}

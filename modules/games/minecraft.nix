{ inputs, lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      secretPath = name: "/run/agenix/${name}";
      ready =
        names:
        lib.all (
          name: builtins.hasAttr name cfg.secretFiles && builtins.pathExists cfg.secretFiles.${name}
        ) names;
      proxySecrets = [
        "games/minecraft/velocity-forwarding"
        "games/minecraft/floodgate-key"
      ];
      dataRoot = "/srv/games/minecraft";
      additions = cfg.minecraftPlugins;
      backend = id: additions.backends.${id};
      lazymc = pkgs.lazymc.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./lazymc-exit.patch ];
      });
      forwardingPath = secretPath "games/minecraft/velocity-forwarding";
      floodgatePath = secretPath "games/minecraft/floodgate-key";
      geyser = pkgs.fetchurl {
        name = "geyser-velocity-2.11.3-1249.jar";
        url = "https://download.geysermc.org/v2/projects/geyser/versions/2.11.3/builds/1249/downloads/velocity";
        sha256 = "0ea113ce061273c52f489bc40a3b287b98875b91b881cebde4d6be342f7a540d";
      };
      floodgate = pkgs.fetchurl {
        name = "floodgate-velocity-2.2.5-141.jar";
        url = "https://download.geysermc.org/v2/projects/floodgate/versions/2.2.5/builds/141/downloads/velocity";
        sha256 = "649835022de37ff09255fc626d4bfe7bc2a3b926d07b0dfaf1f51e12bf37001d";
      };
      # This pinned Velocity release requires Java 25; upstream's generic
      # Velocity wrapper still defaults to Java 21.
      velocity = pkgs.velocityServers.velocity-4_2_0-build_30.override {
        jre_headless = pkgs.jdk25_headless;
      };
      paper =
        s:
        if s.minecraft.package != null then
          s.minecraft.package
        else
          pkgs.paperServers.${"paper-${lib.replaceStrings [ "." ] [ "_" ] s.minecraft.version}"};
      templatesFor =
        id: s:
        let
          dir = "${dataRoot}/${id}";
        in
        {
          "${dir}/config/paper-global.yml" = {
            source = toString (
              (pkgs.formats.yaml { }).generate "${id}-paper-global.yml" {
                "_version" = 31;
                proxies.velocity = {
                  enabled = true;
                  online-mode = true;
                  secret = "@FORWARDING@";
                };
              }
            );
            replacements."@FORWARDING@" = forwardingPath;
          };
          "${dir}/lazymc.toml" = {
            source = toString (
              (pkgs.formats.toml { }).generate "${id}-lazymc.toml" {
                config.version = "0.2.11";
                public = {
                  address = "127.0.0.1:${toString s.minecraft.proxyPort}";
                  version = s.minecraft.version;
                  protocol = 777;
                };
                server = {
                  address = "127.0.0.1:${toString s.minecraft.serverPort}";
                  directory = dir;
                  command = "${lib.getExe (paper s)} ${s.minecraft.jvmOpts}";
                  freeze_process = false;
                  wake_on_start = false;
                  probe_on_start = false;
                  wake_whitelist = false;
                  block_banned_ips = false;
                  start_timeout = 300;
                  stop_timeout = 150;
                };
                time.sleep_after = 900;
                join = {
                  methods = [ "hold" ];
                  hold.timeout = 25;
                };
                rcon = {
                  enabled = true;
                  port = s.minecraft.rconPort;
                  password = "@RCON@";
                  randomize_password = false;
                };
                advanced.rewrite_server_properties = false;
              }
            );
            replacements."@RCON@" = secretPath "games/minecraft/${id}-rcon";
          };
          "${dir}/server.properties" = {
            source = toString (
              pkgs.runCommand "${id}-server.properties"
                {
                  template = pkgs.writeText "${id}-server.properties.in" ''
                    server-ip=127.0.0.1
                    server-port=${toString s.minecraft.serverPort}
                    online-mode=false
                    enforce-secure-profile=false
                    white-list=${lib.boolToString (!(backend id).discordAccessEnabled)}
                    enforce-whitelist=${lib.boolToString (!(backend id).discordAccessEnabled)}
                    enable-rcon=true
                    rcon.port=${toString s.minecraft.rconPort}
                    rcon.password=@RCON@
                    broadcast-rcon-to-ops=false
                    gamemode=survival
                    difficulty=normal
                    level-name=world
                    spawn-protection=0
                    max-players=${toString s.minecraft.maxPlayers}
                    motd=${s.displayName}
                    resource-pack=${cfg.minecraftRankPackUrl}
                    resource-pack-sha1=@RESOURCE_PACK_SHA1@
                    require-resource-pack=true
                    resource-pack-prompt={"text":"This server uses a small resource pack for staff rank icons. Java players must accept it to join."}
                  '';
                }
                ''
                  ${pkgs.python3}/bin/python3 ${./minecraft-resource-pack.py} properties "$template" ${cfg.artifacts.games-rank-icons} "$out"
                ''
            );
            replacements."@RCON@" = secretPath "games/minecraft/${id}-rcon";
          };
        };
      lazyPackage =
        id:
        pkgs.writeShellApplication {
          name = "paper-${id}-lazy";
          text = "exec ${lib.getExe lazymc} --config ${lib.escapeShellArg "${dataRoot}/${id}/lazymc.toml"}";
        };
      proxyConfig = (pkgs.formats.toml { }).generate "velocity.toml" {
        config-version = "2.7";
        bind = "0.0.0.0:25565";
        motd = "<gradient:#cba6f7:#f5c2e7:#fab387><bold>Finn's Survival</bold></gradient>\n<#a6adc8><#cba6f7>mc.finnrut.is</#cba6f7> · survival · 26.3</#a6adc8>";
        show-max-players = 20;
        ping-passthrough = "DISABLED";
        online-mode = true;
        force-key-authentication = true;
        player-info-forwarding-mode = "modern";
        forwarding-secret-file = forwardingPath;
        servers = (lib.mapAttrs (_: s: "127.0.0.1:${toString s.minecraft.proxyPort}") servers) // {
          try = [ cfg.defaultServer ];
        };
        forced-hosts = lib.listToAttrs (
          lib.concatLists (
            lib.mapAttrsToList (
              id: s:
              map (hostname: {
                name = hostname;
                value = [ id ];
              }) s.hostnames
            ) servers
          )
        );
        advanced = {
          connection-timeout = 60000;
          read-timeout = 60000;
        };
      };
    in
    {
      imports = [ inputs.nix-minecraft.nixosModules.minecraft-servers ];
      config = lib.mkIf (servers != { }) {
        nixpkgs.overlays = [ inputs.nix-minecraft.overlays.default ];
        assertions = [
          {
            assertion = lib.all (
              id:
              lib.intersectLists (lib.attrNames servers.${id}.minecraft.plugins) (lib.attrNames (backend id).jars)
              == [ ]
            ) (lib.attrNames servers);
            message = "custom Minecraft plugins must not replace managed plugin names";
          }
          {
            assertion = lib.all (s: s.minecraft.version == "26.3") (lib.attrValues servers);
            message = "managed Minecraft plugins and BlueMap assets are verified for 26.3; recheck pins before changing Paper versions";
          }
          {
            assertion = builtins.hasAttr cfg.defaultServer servers;
            message = "Minecraft default server must be on the Velocity host; move the Minecraft fleet together.";
          }
        ];
        infra.games = {
          minecraftPlugins.backends = lib.genAttrs (lib.attrNames servers) (_: { });
          artifacts = {
            games-velocity = velocity;
            games-geyser = geyser;
            games-floodgate = floodgate;
            games-lazymc = lazymc;
          }
          // lib.listToAttrs (
            lib.concatLists (
              lib.mapAttrsToList (id: s: [
                (lib.nameValuePair "games-paper-${id}" (paper s))
                (lib.nameValuePair "games-${id}-lazy" (lazyPackage id))
              ]) servers
            )
          );
          proxy = {
            id = "velocity";
            serverPort = 25565;
            unit = "minecraft-server-velocity.service";
            dataDir = "${dataRoot}/velocity";
            available = ready proxySecrets;
            secretNames = proxySecrets ++ additions.proxy.secretNames;
            owner = "minecraft";
            pluginInventory = additions.proxy.inventory;
            console = {
              method = "stdin";
              path = "/run/minecraft/velocity.stdin";
            };
            configTemplates = additions.proxy.templates // {
              "${dataRoot}/velocity/plugins/floodgate/key.pem" = {
                secret = floodgatePath;
              };
              "${dataRoot}/velocity/plugins/floodgate/config.yml" = {
                source = toString (
                  (pkgs.formats.yaml { }).generate "floodgate.yml" {
                    config-version = 3;
                    key-file-name = "key.pem";
                    username-prefix = ".";
                    replace-spaces = true;
                    default-locale = "en_US";
                    send-floodgate-data = false;
                    disconnect = {
                      invalid-key = "Please connect through the official Geyser";
                      invalid-arguments-length = "Expected {} arguments, got {}. Is Geyser up-to-date?";
                    };
                    player-link = {
                      enabled = true;
                      require-link = false;
                      enable-own-linking = false;
                      allowed = true;
                      link-code-timeout = 300;
                      type = "sqlite";
                      enable-global-linking = true;
                    };
                    metrics.enabled = false;
                  }
                );
              };
              "${dataRoot}/velocity/plugins/Geyser-Velocity/config.yml" = {
                source = toString (
                  (pkgs.formats.yaml { }).generate "geyser.yml" {
                    config-version = 8;
                    bedrock = {
                      address = "0.0.0.0";
                      port = 19132;
                      transport = "raknet";
                      signaling.mode = "none";
                    };
                    java.auth-type = "floodgate";
                    advanced.floodgate-key-file = floodgatePath;
                  }
                );
              };
            };
          };
          runtime = lib.mapAttrs (id: s: {
            inherit (s)
              game
              displayName
              memoryMax
              backup
              ;
            inherit id;
            owner = "minecraft";
            unit = "minecraft-server-${id}.service";
            container = null;
            dataDir = "${dataRoot}/${id}";
            worldPaths =
              map (name: "${dataRoot}/${id}/${name}") [
                "world"
                "world_nether"
                "world_the_end"
              ]
              ++ (backend id).statePaths;
            pluginInventory = (backend id).inventory;
            datapackInventory = cfg.minecraftDatapacks.backends.${id}.inventory;
            mapUrl = "https://map.finnrut.is";
            discordInviteUrl =
              if s.minecraft.discord.inviteUrl == "" then null else s.minecraft.discord.inviteUrl;
            public =
              lib.concatMap (hostname: [
                {
                  inherit hostname;
                  port = 25565;
                  protocol = "tcp";
                  edition = "java";
                }
                {
                  inherit hostname;
                  port = 19132;
                  protocol = "udp";
                  edition = "bedrock";
                }
              ]) s.hostnames
              ++ [
                {
                  hostname = lib.head s.hostnames;
                  port = s.minecraft.voicechatPort;
                  protocol = "udp";
                  edition = "voice chat";
                }
              ];
            internalPorts = [
              s.minecraft.proxyPort
              s.minecraft.serverPort
              s.minecraft.rconPort
              s.minecraft.metricsPort
            ];
            publicTCPPorts = [ ];
            publicUDPPorts = [ s.minecraft.voicechatPort ];
            wakeOnJoin = true;
            serverPort = s.minecraft.serverPort;
            childExitFile = "/run/games/${id}/paper-exit.json";
            secretNames = proxySecrets ++ [ "games/minecraft/${id}-rcon" ] ++ (backend id).secretNames;
            available = ready (proxySecrets ++ [ "games/minecraft/${id}-rcon" ]);
            console = {
              method = "rcon";
              host = "127.0.0.1";
              port = s.minecraft.rconPort;
              passwordFile = secretPath "games/minecraft/${id}-rcon";
            };
            fingerprint = builtins.hashString "sha256" (
              builtins.toJSON {
                package = toString (paper s);
                plugins = s.minecraft.plugins // (backend id).jars;
                datapacks = cfg.minecraftDatapacks.backends.${id}.packs;
                templates = templatesFor id s // (backend id).templates;
              }
            );
            configTemplates = templatesFor id s // (backend id).templates;
          }) servers;
        };
        services.minecraft-servers = {
          enable = true;
          eula = true;
          dataDir = dataRoot;
          openFirewall = false;
          managementSystem = {
            tmux.enable = false;
            systemd-socket.enable = true;
          };
          servers = {
            velocity = {
              enable = ready proxySecrets;
              package = velocity;
              jvmOpts = "-Xms128M -Xmx512M";
              stopCommand = "end";
              files."velocity.toml" = proxyConfig;
              symlinks =
                lib.mapAttrs' (
                  name: artifact: lib.nameValuePair "plugins/${name}.jar" artifact
                ) additions.proxy.jars
                // {
                  "plugins/geyser.jar" = geyser;
                  "plugins/floodgate.jar" = floodgate;
                };
            };
          }
          // lib.mapAttrs (id: s: {
            enable = cfg.runtime.${id}.available;
            package = lazyPackage id;
            jvmOpts = "";
            stopCommand = null;
            files = {
              # Paths deliberately bypass upstream's omission of empty values.
              "whitelist.json" = pkgs.writeText "${id}-whitelist.json" (
                builtins.toJSON (
                  lib.mapAttrsToList (name: uuid: { inherit name uuid; }) (
                    if (backend id).discordAccessEnabled then
                      lib.filterAttrs (_: uuid: uuid == cfg.minecraftAdminUuid) s.minecraft.whitelist
                    else
                      s.minecraft.whitelist
                  )
                )
              );
              "ops.json" = pkgs.writeText "${id}-ops.json" (
                builtins.toJSON (
                  lib.mapAttrsToList (name: uuid: {
                    inherit name uuid;
                    level = 4;
                    bypassesPlayerLimit = false;
                  }) s.minecraft.operators
                )
              );
              "spigot.yml".value.settings.bungeecord = false;
            };
            symlinks = lib.mapAttrs' (name: artifact: lib.nameValuePair "plugins/${name}.jar" artifact) (
              s.minecraft.plugins // (backend id).jars
            );
          }) servers;
        };
        systemd.services = {
          minecraft-server-velocity = {
            enable = ready proxySecrets;
            serviceConfig = {
              Slice = "games.slice";
              MemoryMax = "1G";
              CPUAccounting = true;
              MemoryAccounting = true;
              IOAccounting = true;
              ExecStartPre = lib.mkAfter [ "+${lib.getExe cfg.packages.prepare} velocity" ];
            };
          };
        }
        // lib.mapAttrs' (
          id: s:
          lib.nameValuePair "minecraft-server-${id}" {
            enable = cfg.runtime.${id}.available;
            environment.GAMES_PAPER_EXIT_FILE = cfg.runtime.${id}.childExitFile;
            serviceConfig = {
              Slice = "games.slice";
              MemoryMax = s.memoryMax;
              CPUAccounting = true;
              MemoryAccounting = true;
              IOAccounting = true;
              TimeoutStartSec = "40min";
              TimeoutStopSec = lib.mkForce 180;
              ExecStart = lib.mkForce (lib.getExe (lazyPackage id));
              ExecStartPre = lib.mkMerge [
                (lib.mkBefore [ "+${lib.getExe cfg.packages.prechange} ${id}" ])
                (lib.mkAfter [ "+${lib.getExe cfg.packages.prepare} ${id}" ])
              ];
              ExecStop = lib.mkForce "+${lib.getExe cfg.packages.paper-stop} ${id} $MAINPID";
              ExecStopPost = [ "+${lib.getExe cfg.packages.paper-result} ${id}" ];
            };
          }
        ) servers;
      };
    };
}

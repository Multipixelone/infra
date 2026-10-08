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
              pkgs.writeText "${id}-server.properties" ''
                server-ip=127.0.0.1
                server-port=${toString s.minecraft.serverPort}
                online-mode=false
                enforce-secure-profile=false
                white-list=true
                enforce-whitelist=true
                enable-rcon=true
                rcon.port=${toString s.minecraft.rconPort}
                rcon.password=@RCON@
                broadcast-rcon-to-ops=false
                gamemode=survival
                difficulty=normal
                level-name=world
                motd=${s.displayName}
              ''
            );
            replacements."@RCON@" = secretPath "games/minecraft/${id}-rcon";
          };
        };
      lazyPackage =
        id:
        pkgs.writeShellApplication {
          name = "paper-${id}-lazy";
          text = "exec ${lib.getExe pkgs.lazymc} --config ${lib.escapeShellArg "${dataRoot}/${id}/lazymc.toml"}";
        };
      proxyConfig = (pkgs.formats.toml { }).generate "velocity.toml" {
        config-version = "2.7";
        bind = "0.0.0.0:25565";
        motd = "Finn's Minecraft servers";
        show-max-players = 20;
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
            assertion = builtins.hasAttr cfg.defaultServer servers;
            message = "Minecraft default server must be on the Velocity host; move the Minecraft fleet together.";
          }
        ];
        infra.games = {
          artifacts = {
            games-velocity = velocity;
            games-geyser = geyser;
            games-floodgate = floodgate;
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
            unit = "minecraft-server-velocity.service";
            dataDir = "${dataRoot}/velocity";
            available = ready proxySecrets;
            secretNames = proxySecrets;
            owner = "minecraft";
            console = {
              method = "stdin";
              path = "/run/minecraft/velocity.stdin";
            };
            configTemplates = {
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
                      enabled = false;
                      require-link = false;
                      enable-own-linking = false;
                      allowed = true;
                      link-code-timeout = 300;
                      type = "sqlite";
                      enable-global-linking = false;
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
            id = id;
            owner = "minecraft";
            unit = "minecraft-server-${id}.service";
            container = null;
            dataDir = "${dataRoot}/${id}";
            worldPaths = map (name: "${dataRoot}/${id}/${name}") [
              "world"
              "world_nether"
              "world_the_end"
            ];
            public = lib.concatMap (hostname: [
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
            ]) s.hostnames;
            internalPorts = [
              s.minecraft.proxyPort
              s.minecraft.serverPort
              s.minecraft.rconPort
            ];
            publicTCPPorts = [ ];
            publicUDPPorts = [ ];
            wakeOnJoin = true;
            serverPort = s.minecraft.serverPort;
            secretNames = proxySecrets ++ [ "games/minecraft/${id}-rcon" ];
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
                inherit (s.minecraft) plugins;
              }
            );
            configTemplates = templatesFor id s;
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
              symlinks = {
                "velocity.toml" = proxyConfig;
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
                builtins.toJSON (lib.mapAttrsToList (name: uuid: { inherit name uuid; }) s.minecraft.whitelist)
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
            symlinks = lib.mapAttrs' (
              name: artifact: lib.nameValuePair "plugins/${name}.jar" artifact
            ) s.minecraft.plugins;
          }) servers;
        };
        systemd.services = {
          minecraft-server-velocity = {
            enable = ready proxySecrets;
            serviceConfig = {
              Slice = "games.slice";
              MemoryMax = "1G";
              ExecStartPre = lib.mkAfter [ "+${lib.getExe cfg.packages.prepare} velocity" ];
            };
          };
        }
        // lib.mapAttrs' (
          id: s:
          lib.nameValuePair "minecraft-server-${id}" {
            enable = cfg.runtime.${id}.available;
            serviceConfig = {
              Slice = "games.slice";
              MemoryMax = s.memoryMax;
              TimeoutStartSec = "40min";
              TimeoutStopSec = 180;
              ExecStart = lib.mkForce (lib.getExe (lazyPackage id));
              ExecStartPre = lib.mkMerge [
                (lib.mkBefore [ "+${lib.getExe cfg.packages.prechange} ${id}" ])
                (lib.mkAfter [ "+${lib.getExe cfg.packages.prepare} ${id}" ])
              ];
              ExecStop = lib.mkForce "+${lib.getExe cfg.packages.paper-stop} ${id} $MAINPID";
            };
          }
        ) servers;
      };
    };
}

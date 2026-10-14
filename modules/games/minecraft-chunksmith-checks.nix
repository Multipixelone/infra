{ config, lib, ... }:
let
  host = config.flake.nixosConfigurations.link;
  cfg = host.config;
  project = c: {
    backends = c.infra.games.minecraftPlugins.backends;
    runtime = lib.mapAttrs (_: s: {
      inherit (s)
        public
        publicTCPPorts
        publicUDPPorts
        worldPaths
        ;
    }) (lib.filterAttrs (_: s: s.game == "minecraft-paper") c.infra.games.runtime);
    symlinks = lib.mapAttrs (_: s: s.symlinks) c.services.minecraft-servers.servers;
    tcp = c.networking.firewall.allowedTCPPorts;
    udp = c.networking.firewall.allowedUDPPorts;
  };
  additional =
    (host.extendModules {
      modules = [
        {
          infra.games.secretFiles = lib.mkForce { };
          infra.games.servers.testing = cfg.infra.games.servers.survival // {
            hostnames = [ "testing.mc.finnrut.is" ];
            minecraft = cfg.infra.games.servers.survival.minecraft // {
              serverPort = 25577;
              proxyPort = 25576;
              rconPort = 25585;
              voicechatPort = 24455;
              metricsPort = 9226;
            };
          };
        }
      ];
    }).config;
  without =
    (host.extendModules {
      modules = [ { infra.games.servers = lib.mkForce { }; } ];
    }).config;
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.games-minecraft-chunksmith =
        pkgs.runCommand "games-minecraft-chunksmith-check"
          {
            nativeBuildInputs = [
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
              pkgs.jdk25_headless
            ];
          }
          ''
            export PYTHONDONTWRITEBYTECODE=1
            python3 ${./tests/minecraft_chunksmith_test.py} \
              ${
                pkgs.writeText "minecraft-chunksmith-fixtures.json" (
                  builtins.toJSON {
                    production = project cfg;
                    additional = project additional;
                    without = without.infra.games.minecraftPlugins.backends;
                    plugin = toString cfg.infra.games.artifacts.games-chunksmith;
                  }
                )
              } \
              ${./tests/CheckChunksmith.java} \
              ${
                pkgs.fetchurl {
                  url = "https://repo.maven.apache.org/maven2/org/slf4j/slf4j-api/2.0.17/slf4j-api-2.0.17.jar";
                  sha256 = "7b751d952061954d5abfed7181c1f645d336091b679891591d63329c622eb832";
                }
              } \
              ${
                # Client compatibility fixtures only: never installed on the host.
                pkgs.fetchurl {
                  url = "https://cdn.modrinth.com/data/4BeAEBIb/versions/Sun3j32A/chunksmith-4.6.0%2B26.3.jar";
                  hash = "sha256-Oac5UDoj6GE4K77vY4TPJZxLAs0j0Dk5opm1B1yufUA=";
                }
              } \
              ${
                pkgs.fetchurl {
                  url = "https://cdn.modrinth.com/data/uCdwusMi/versions/TGgEbP9A/DistantHorizons-3.3.4-26.3-fabric-neoforge.jar";
                  hash = "sha256-uj5chadloQkhmDHfmbme9c/N7gWy36Z5YRaZO9SNOUc=";
                }
              } \
              ${pkgs.fetchurl {
                # Minecraft supplies this dependency at runtime; mirror the
                # pinned Paper plugin checks in the isolated test classpath.
                url = "https://repo.maven.apache.org/maven2/com/google/code/gson/gson/2.14.0/gson-2.14.0.jar";
                sha256 = "2cbd119bf1961c28788310963dc80ba65f58cdeec1dd139c8bdb1240faa2c36f";
              }}
            touch "$out"
          '';
    };
}

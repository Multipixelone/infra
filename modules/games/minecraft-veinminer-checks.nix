{ config, lib, ... }:
let
  host = config.flake.nixosConfigurations.link;
  cfg = host.config;
  base = cfg.infra.games.servers;
  fixture = c: {
    backends = lib.mapAttrs (id: p: {
      jars = lib.filterAttrs (name: _: name == "veinminer") p.jars;
      templates = lib.filterAttrs (path: _: lib.hasInfix "/plugins/Veinminer/" path) p.templates;
      inventory = lib.filter (p: p.name == "Veinminer") p.inventory;
      inherit (c.infra.games.runtime.${id}) available worldPaths;
      symlinks = c.services.minecraft-servers.servers.${id}.symlinks;
      bstats = p.templates."/srv/games/minecraft/${id}/plugins/bStats/config.yml".source;
    }) c.infra.games.minecraftPlugins.backends;
    proxyJars = lib.attrNames c.infra.games.minecraftPlugins.proxy.jars;
    permissions =
      c.infra.games.minecraftPlugins.backends.survival.templates."/srv/games/minecraft/survival/plugins/LuckPerms/bootstrap.json.gz".source
        or null;
    permissionCommands =
      c.infra.games.minecraftPlugins.backends.survival.templates."/srv/games/minecraft/survival/plugins/LuckPerms/chat-inventory.commands".source
        or null;
  };
  fixtures = {
    withLuckPerms =
      fixture
        (host.extendModules {
          modules = [
            {
              infra.games.secretFiles = lib.mkForce {
                "games/minecraft/luckperms-db-password" = ./tests/fixture.age;
              };
            }
          ];
        }).config;
    missingSecrets =
      fixture
        (host.extendModules {
          modules = [ { infra.games.secretFiles = lib.mkForce { }; } ];
        }).config;
    additionalBackend =
      fixture
        (host.extendModules {
          modules = [
            {
              infra.games.secretFiles = lib.mkForce { };
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
      fixture
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
    checks.games-minecraft-veinminer =
      let
        guava = pkgs.fetchurl {
          url = "https://repo.maven.apache.org/maven2/com/google/guava/guava/33.6.0-jre/guava-33.6.0-jre.jar";
          sha256 = "dc573e1fca4fd5454f4a5fd3d7da2df03002876a4175bafc14a95980dd7713b3";
        };
        gson = pkgs.fetchurl {
          url = "https://repo.maven.apache.org/maven2/com/google/code/gson/gson/2.14.0/gson-2.14.0.jar";
          sha256 = "2cbd119bf1961c28788310963dc80ba65f58cdeec1dd139c8bdb1240faa2c36f";
        };
        # Minecraft supplies this outside Paper's embedded test library bundle.
        slf4j = pkgs.fetchurl {
          url = "https://repo.maven.apache.org/maven2/org/slf4j/slf4j-api/2.0.17/slf4j-api-2.0.17.jar";
          sha256 = "7b751d952061954d5abfed7181c1f645d336091b679891591d63329c622eb832";
        };
      in
      pkgs.runCommand "games-minecraft-veinminer-check"
        {
          nativeBuildInputs = [
            (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
            pkgs.jdk25_headless
          ];
        }
        ''
          python3 ${./tests/minecraft_veinminer_test.py} \
            ${pkgs.writeText "minecraft-veinminer-fixtures.json" (builtins.toJSON fixtures)} \
            ${cfg.infra.games.artifacts.games-veinminer} \
            ${cfg.infra.games.artifacts.games-veinminer-libraries} \
            ${cfg.infra.games.artifacts.games-paper-survival}/lib/minecraft/server.jar \
            ${cfg.infra.games.artifacts.games-geyser} \
            ${guava} ${gson} ${slf4j} ${./tests}
          touch "$out"
        '';
  };
}

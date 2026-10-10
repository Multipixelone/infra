{ config, lib, ... }:
let
  host = config.flake.nixosConfigurations.link;
  cfg = host.config;
  base = cfg.infra.games.servers;
  fixture = c: {
    backends = c.infra.games.minecraftPlugins.backends;
    proxyJars = lib.attrNames c.infra.games.minecraftPlugins.proxy.jars;
    servers = lib.mapAttrs (id: _: {
      inherit (c.infra.games.runtime.${id}) available worldPaths;
      symlinks = c.services.minecraft-servers.servers.${id}.symlinks;
    }) (lib.filterAttrs (_: s: s.game == "minecraft-paper") c.infra.games.servers);
  };
  fixtures = {
    # Optional QoL plugins do not bypass the mandatory credential gate.
    missingSecrets =
      fixture
        (host.extendModules {
          modules = [
            {
              infra.games.secretFiles = lib.mkForce { };
            }
          ];
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
    checks.games-minecraft-qol =
      let
        # Minecraft supplies these at runtime; provide the exact versions only
        # for parser/cache tests without starting a live Minecraft server.
        guava = pkgs.fetchurl {
          url = "https://repo.maven.apache.org/maven2/com/google/guava/guava/33.6.0-jre/guava-33.6.0-jre.jar";
          sha256 = "dc573e1fca4fd5454f4a5fd3d7da2df03002876a4175bafc14a95980dd7713b3";
        };
        gson = pkgs.fetchurl {
          url = "https://repo.maven.apache.org/maven2/com/google/code/gson/gson/2.14.0/gson-2.14.0.jar";
          sha256 = "2cbd119bf1961c28788310963dc80ba65f58cdeec1dd139c8bdb1240faa2c36f";
        };
        examinationApi = pkgs.fetchurl {
          url = "https://repo.maven.apache.org/maven2/net/kyori/examination-api/1.3.0/examination-api-1.3.0.jar";
          sha256 = "c9237ffecb05428f6eff86216246ac70ce0b47b04c08ea7ca35020fde57f8492";
        };
        examinationString = pkgs.fetchurl {
          url = "https://repo.maven.apache.org/maven2/net/kyori/examination-string/1.3.0/examination-string-1.3.0.jar";
          sha256 = "7d01fc25a4bb3af0e1662685455f4541fbf4626216ea5846e455c1491e156b8c";
        };
        fastutil = pkgs.fetchurl {
          url = "https://repo.maven.apache.org/maven2/it/unimi/dsi/fastutil/8.5.18/fastutil-8.5.18.jar";
          sha256 = "9094ae67d01d0ad246f886f11ad557fc2e79c72cbf3feed83e1512a8ae90a74a";
        };
      in
      pkgs.runCommand "games-minecraft-qol-check"
        {
          nativeBuildInputs = [
            (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
            pkgs.jdk25_headless
          ];
        }
        ''
          python3 ${./tests/minecraft_qol_test.py} \
            ${pkgs.writeText "minecraft-qol-fixtures.json" (builtins.toJSON fixtures)} \
            ${cfg.infra.games.artifacts.games-huskhomes} \
            ${cfg.infra.games.artifacts.games-axgraves} \
            ${cfg.infra.games.artifacts.games-huskhomes-libraries} \
            ${cfg.infra.games.artifacts.games-axgraves-libraries} \
            ${cfg.infra.games.artifacts.games-paper-survival}/lib/minecraft/server.jar \
            ${guava} ${fastutil} ${./tests} \
            ${cfg.infra.games.artifacts.games-openinv} \
            ${cfg.infra.games.artifacts.games-openinv-libraries} \
            ${cfg.infra.games.artifacts.games-bluemap-offline} ${gson} \
            ${examinationApi} ${examinationString}
          touch "$out"
        '';
  };
}

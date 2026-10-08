{ config, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        host = config.flake.nixosConfigurations.link;
        homepage = import ../../lib/games-homepage.nix { inherit lib; };
        secrets = lib.genAttrs [
          "games/minecraft/velocity-forwarding"
          "games/minecraft/floodgate-key"
          "games/minecraft/survival-rcon"
          "games/minecraft/creative-rcon"
          "games/terraria/terraria-password"
        ] (_: ./tests/fixture.age);
        extend =
          extra:
          (host.extendModules {
            modules = [
              { infra.games.secretFiles = lib.mkForce secrets; }
              extra
            ];
          }).config;
        enabled = extend { };
        missing =
          (host.extendModules {
            modules = [ { infra.games.secretFiles = lib.mkForce { }; } ];
          }).config;
        empty = extend { infra.games.servers = lib.mkForce { }; };
        disabled = extend {
          infra.games.servers = lib.mkForce (
            host.config.infra.games.servers
            // {
              survival = host.config.infra.games.servers.survival // {
                enable = false;
              };
            }
          );
        };
        stopped = extend { systemd.services.minecraft-server-survival.enable = lib.mkForce false; };
        discovered = extend {
          infra.games.servers.creative = host.config.infra.games.servers.survival // {
            displayName = "Creative";
            hostnames = [ "creative.mc.finnrut.is" ];
            minecraft = host.config.infra.games.servers.survival.minecraft // {
              proxyPort = 25576;
              serverPort = 25577;
              rconPort = 25585;
            };
          };
        };
        url = "https://games.nyc.finnrut.is";
        fixture = pkgs.writeText "games-homepage-fixtures.json" (
          builtins.toJSON {
            services = lib.genAttrs [ "enabled" "missing" "empty" "disabled" "stopped" "discovered" ] (
              name:
              {
                inherit
                  enabled
                  missing
                  empty
                  disabled
                  stopped
                  discovered
                  ;
              }
              .${name}.services.homepage-dashboard.services
            );
            adapter = enabled.systemd.services.games-homepage-status.serviceConfig;
            adapterMissing = missing.systemd.services ? games-homepage-status;
            tcp = enabled.networking.firewall.allowedTCPPorts;
            udp = enabled.networking.firewall.allowedUDPPorts;
            deduplicated = homepage.appendGroups [
              { Media = [ { Plex.href = "https://plex.example.test"; } ]; }
              { Games = [ { Other.description = "keep me"; } ]; }
              { Infrastructure = [ { Games.href = url; } ]; }
            ] (homepage.tiles { } url) url;
            alternate = homepage.tiles { } "https://games.example.test";
          }
        );
      in
      {
        checks.games-homepage =
          pkgs.runCommand "games-homepage-check"
            {
              nativeBuildInputs = [ pkgs.python3 ];
              passthru.fixtureServicesYaml = enabled.environment.etc."homepage-dashboard/services.yaml".source;
            }
            ''
              export PYTHONDONTWRITEBYTECODE=1
              python3 ${./tests/homepage_test.py} ${fixture} ${./homepage-status.py}
              touch "$out"
            '';
      }
    );
}

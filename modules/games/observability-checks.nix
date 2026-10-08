{ config, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      host = config.flake.nixosConfigurations.link;
      cfg = host.config;
      rules = pkgs.writeText "game-alerts.json" (
        builtins.toJSON (
          import ../../lib/game-alerts.nix {
            host = "link";
            grafanaHost = config.flake.servicePublicationInventory.applications.grafana.canonical;
            logPanelId =
              (lib.findFirst (panel: panel.type == "logs") (throw "Game Servers has no logs panel")
                config.flake.grafanaDashboards."game-servers.json".panels
              ).id;
          }
        )
      );
      missing =
        (host.extendModules { modules = [ { infra.games.secretFiles = lib.mkForce { }; } ]; }).config;
      disabled =
        (host.extendModules {
          modules = [
            {
              infra.games.servers = lib.mkForce { };
              infra.games.registeredServers = lib.mkForce (
                lib.mapAttrs (_: server: server // { enable = false; }) cfg.infra.games.registeredServers
              );
            }
          ];
        }).config;
      enabled =
        (host.extendModules {
          modules = [
            {
              infra.games.secretFiles = lib.mkForce (
                lib.genAttrs [
                  "games/minecraft/velocity-forwarding"
                  "games/minecraft/floodgate-key"
                  "games/minecraft/survival-rcon"
                  "games/terraria/terraria-password"
                  "games/restic-password"
                ] (_: ./tests/fixture.age)
              );
              infra.games.backup.enable = lib.mkForce true;
            }
          ];
        }).config;
      discovered =
        (host.extendModules {
          modules = [
            {
              infra.games.servers = lib.mkForce (
                cfg.infra.games.servers
                // {
                  creative = cfg.infra.games.servers.survival // {
                    hostnames = [ "creative.mc.finnrut.is" ];
                    minecraft = cfg.infra.games.servers.survival.minecraft // {
                      proxyPort = 25576;
                      serverPort = 25577;
                      rconPort = 25585;
                    };
                  };
                }
              );
              infra.games.secretFiles = lib.mkForce { };
            }
          ];
        }).config;
      contract = pkgs.writeText "games-observability-contract.json" (
        builtins.toJSON {
          missing = missing.infra.games.observability.inventory;
          disabled = disabled.infra.games.observability.inventory;
          enabled = enabled.infra.games.observability.inventory;
          discovered = discovered.infra.games.observability.inventory;
          manifest = builtins.fromJSON cfg.environment.etc."games/manifest.json".text;
          alloy = cfg.environment.etc."alloy/config.alloy".text;
          exporter = cfg.systemd.services.games-metrics.serviceConfig;
          exporterFlags = cfg.services.prometheus.exporters.node.extraFlags;
          backupOnFailure = enabled.systemd.services.restic-backups-games-survival.onFailure;
          proxyConfig = toString enabled.services.minecraft-servers.servers.velocity.symlinks."velocity.toml";
        }
      );
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      checks = {
        games-metrics =
          pkgs.runCommand "games-metrics-check"
            {
              nativeBuildInputs = [
                pkgs.python3
                pkgs.prometheus.cli
              ];
            }
            ''
              export PYTHONDONTWRITEBYTECODE=1
              python3 ${./tests/metrics_test.py} ${./metrics.py} ${./log-patterns.json} ${./tests/status-fixtures.json}
              python3 ${./tests/metrics_exposition.py} ${./metrics.py} ${./log-patterns.json} > "$TMPDIR/games.prom"
              promtool check metrics < "$TMPDIR/games.prom"
              touch "$out"
            '';
        games-alerts =
          pkgs.runCommand "games-alerts-check"
            {
              nativeBuildInputs = [
                pkgs.python3
                pkgs.prometheus.cli
              ];
            }
            ''
              promtool check rules ${rules}
              python3 ${./tests/alerts_test.py} ${rules} "$TMPDIR/game-alert-tests.json"
              promtool test rules "$TMPDIR/game-alert-tests.json"
              touch "$out"
            '';
        games-alloy =
          pkgs.runCommand "games-alloy-check" { nativeBuildInputs = [ cfg.services.alloy.package ]; }
            ''
              alloy validate ${pkgs.writeText "alloy-games.alloy" cfg.environment.etc."alloy/config.alloy".text}
              touch "$out"
            '';
        games-observability-contract =
          pkgs.runCommand "games-observability-contract-check" { nativeBuildInputs = [ pkgs.python3 ]; }
            ''
              python3 ${./tests/observability_contract.py} ${contract}
              touch "$out"
            '';
      };
    };
}

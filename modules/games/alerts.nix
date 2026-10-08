{ config, lib, ... }:
{
  configurations.nixos.link.module = { pkgs, ... }: {
    services.prometheus.ruleFiles = [
      ((pkgs.formats.yaml { }).generate "game-alerts.yaml" (
        import ../../lib/game-alerts.nix {
          host = "link";
          grafanaHost = config.flake.servicePublicationInventory.applications.grafana.canonical;
          logPanelId =
            (lib.findFirst (panel: panel.type == "logs") (throw "Game Servers has no logs panel")
              config.flake.grafanaDashboards."game-servers.json".panels
            ).id;
        }
      ))
    ];
  };
}

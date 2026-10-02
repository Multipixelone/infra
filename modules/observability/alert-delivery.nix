{ config, lib, ... }:
let
  flakeConfig = config;
  inherit (config.observability) nodes;
  delivery = import ../../lib/alert-delivery.nix { inherit lib; };
  runbook = "https://git.finnrut.is/tunnel/infra/src/branch/main/docs/observability-phase1.md#systemd-alert-response";
in
{
  # Read-only projection for focused evaluation/contracts. No host's
  # systemd/onFailure definitions depend on this cross-host projection.
  flake.alertDeliveryOptIns = lib.mapAttrs (
    host: _: delivery.optedInUnits flakeConfig.flake.nixosConfigurations.${host}.config
  ) nodes;

  configurations.nixos = lib.mkMerge [
    (lib.mapAttrs (host: _: {
      module = { config, ... }: {
        services.prometheus.exporters.node = {
          enabledCollectors = lib.mkDefault [ "systemd" ];
          # Keep generic systemd telemetry, including opted-in mounts/slices.
          # The upstream default exclusion would otherwise hide these types.
          extraFlags = [
            "--collector.systemd.unit-include=.+"
            "--collector.systemd.unit-exclude=^$"
          ];
        };
        assertions = [
          {
            assertion =
              config.services.prometheus.exporters.node.enable
              && lib.elem "systemd" config.services.prometheus.exporters.node.enabledCollectors
              && !lib.elem "systemd" config.services.prometheus.exporters.node.disabledCollectors
              &&
                builtins.filter (
                  flag: lib.hasPrefix "--collector.systemd.unit-" flag
                ) config.services.prometheus.exporters.node.extraFlags == [
                  "--collector.systemd.unit-include=.+"
                  "--collector.systemd.unit-exclude=^$"
                ];
            message = "${host} opted-in failure alerts require an enabled systemd collector without conflicting unit filters.";
          }
        ];
      };
    }) nodes)
    {

      link.module =
        { config, pkgs, ... }:
        let
          # Crucially use Link's own module config here, never re-enter its
          # nixosConfigurations evaluation while constructing its rule file.
          unitsByHost = lib.mapAttrs (
            host: _:
            delivery.optedInUnits (
              if host == "link" then config else flakeConfig.flake.nixosConfigurations.${host}.config
            )
          ) nodes;
          rules = lib.concatLists (
            lib.mapAttrsToList (
              host: units:
              lib.optional (units != [ ]) {
                alert = "OptedInUnitFailed";
                expr = ''max_over_time(node_systemd_unit_state{job="${
                  flakeConfig.hosts.${host}.hostName
                }-node",instance="${
                  flakeConfig.hosts.${host}.hostName
                }",state="failed",name=~${builtins.toJSON (delivery.unitRegex units)}}[2m]) == 1'';
                for = "0s";
                labels = {
                  severity = "critical";
                  host = flakeConfig.hosts.${host}.hostName;
                  unit = "{{ $labels.name }}";
                };
                annotations = {
                  summary = "Systemd unit {{ $labels.name }} failed on ${flakeConfig.hosts.${host}.hostName}";
                  description = "Run journalctl -u {{ $labels.name }} -n 50 on ${flakeConfig.hosts.${host}.hostName}";
                  inherit runbook;
                }
                // lib.optionalAttrs (host == "link") {
                  # Encode the whole pane JSON after inserting the real unit name.
                  logs = ''https://${flakeConfig.flake.servicePublicationInventory.applications.grafana.canonical}/explore?schemaVersion=1&orgId=1&panes={{ printf "{\"a\":{\"datasource\":\"loki\",\"queries\":[{\"refId\":\"A\",\"datasource\":{\"type\":\"loki\",\"uid\":\"loki\"},\"expr\":%q}],\"range\":{\"from\":\"now-1h\",\"to\":\"now\"}}}" (printf "{host=\"link\",unit=%q}" $labels.name) | urlquery }}'';
                };
              }
            ) unitsByHost
          );
        in
        {
          services.prometheus.ruleFiles = [
            ((pkgs.formats.yaml { }).generate "opted-in-unit-rules.yaml" {
              groups = [
                {
                  name = "opted-in-unit-alerts";
                  interval = "30s";
                  inherit rules;
                }
              ];
            })
          ];
        };
    }
  ];
}

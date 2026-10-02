{ config, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      hosts = config.flake.nixosConfigurations;
      link = hosts.link.config;
      python = pkgs.python3.withPackages (p: [ p.pyyaml ]);
      delivery = import ../../lib/alert-delivery.nix { inherit lib; };
      fixtureUnits = delivery.optedInUnits {
        systemd = {
          services = {
            opted = {
              name = "fixture.service";
              onFailure = [
                "other.service"
                "notify-telegram@%n.service"
              ];
            };
            disabled = {
              name = "disabled.service";
              enable = false;
              onFailure = [ "notify-telegram@%n.service" ];
            };
            unrelated = {
              name = "unrelated.service";
              onFailure = [ "other.service" ];
            };
            template = {
              name = "fixture@.service";
              onFailure = [ "notify-telegram@%n.service" ];
            };
          };
          sockets.fixture = {
            name = "fixture.socket";
            onFailure = [ "notify-telegram@%n.service" ];
          };
        };
      };
      contract = pkgs.writeText "alert-delivery-contract.json" (
        builtins.toJSON {
          inventory = config.flake.alertDeliveryOptIns;
          helperFixture = {
            units = fixtureUnits;
            regex = delivery.unitRegex fixtureUnits;
          };
          hosts =
            lib.genAttrs
              (builtins.attrNames (lib.filterAttrs (host: _: (config.hosts.${host}.isNixOS or false)) hosts))
              (
                host:
                let
                  cfg = hosts.${host}.config;
                in
                {
                  notifier = cfg.systemd.services."notify-telegram@".serviceConfig;
                  collector = cfg.services.prometheus.exporters.node;
                  assertions = map (assertion: assertion.assertion) cfg.assertions;
                }
              );
        }
      );
      directScript = builtins.head (
        lib.splitString " " hosts.zelda.config.systemd.services."notify-telegram@".serviceConfig.ExecStart
      );
      gatewayScript = link.systemd.services.openclaw-service-metrics.serviceConfig.ExecStart;
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.alert-delivery-contracts =
        pkgs.runCommand "alert-delivery-contracts-check"
          {
            TZDIR = "${pkgs.tzdata}/share/zoneinfo";
            nativeBuildInputs = [
              python
              pkgs.prometheus.cli
              pkgs.bash
              pkgs.coreutils
              pkgs.jq
            ];
          }
          ''
            python3 ${./fixtures}/check-unit-alerts.py ${contract} ${lib.escapeShellArgs link.services.prometheus.ruleFiles}
            promtool test rules unit-suite.json
            python3 ${./fixtures}/check-direct-notify.py ${directScript} ${gatewayScript} ${pkgs.writeText "alert-format.sh" (import ../../lib/alert-format.nix)}
            touch "$out"
          '';
    };
}

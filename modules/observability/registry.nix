{ lib, config, ... }:
let
  endpointType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        dnsName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Private DNS name, when the endpoint has a browser-facing frontend.";
        };
        backendAddress = lib.mkOption {
          type = lib.types.strMatching "(127\\.[0-9]+\\.[0-9]+\\.[0-9]+|::1)";
          default = "127.0.0.1";
          description = "Loopback address used by the service backend.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          description = "Backend TCP port.";
        };
        exposure = lib.mkOption {
          type = lib.types.enum [
            "loopback"
            "private"
          ];
          default = "loopback";
          description = "Maximum intended exposure. Phase 1 deliberately has no public value.";
        };
        homepage = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether Homepage should link to this endpoint.";
        };
        probe = lib.mkOption {
          type = lib.types.nullOr (
            lib.types.submodule {
              options = {
                internalPath = lib.mkOption {
                  type = lib.types.str;
                  default = "/";
                };
                privatePath = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                };
                sloClass = lib.mkOption {
                  type = lib.types.enum [
                    "internal"
                    "public"
                  ];
                  default = "internal";
                };
              };
            }
          );
          default = null;
          description = "Blackbox paths and SLO class. Targets are generated and never self-modify.";
        };
        description = lib.mkOption {
          type = lib.types.str;
          default = name;
        };
      };
    }
  );
in
{
  options.observability = {
    hubHost = lib.mkOption {
      type = lib.types.str;
      description = "Host that runs the Phase 1 observability stack.";
    };
    trustedClientCidrs = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+");
      description = "Only client networks allowed to reach private DNS and HTTPS.";
    };
    privateZone = lib.mkOption {
      type = lib.types.str;
    };
    retention = {
      prometheusTime = lib.mkOption { type = lib.types.str; };
      prometheusSize = lib.mkOption { type = lib.types.str; };
      loki = lib.mkOption { type = lib.types.str; };
      hardFilesystemCaps = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };
    };
    slo = {
      availability = lib.mkOption { type = lib.types.float; };
      window = lib.mkOption { type = lib.types.str; };
      latencySeconds = {
        internal = lib.mkOption { type = lib.types.float; };
        public = lib.mkOption { type = lib.types.float; };
      };
    };
    endpoints = lib.mkOption {
      type = lib.types.attrsOf endpointType;
      description = "Typed, Link-only Phase 1 service and probe registry.";
    };
  };

  config = {
    observability = {
      hubHost = "link";
      trustedClientCidrs = [
        "192.168.5.0/24"
        "192.168.6.0/24"
        "10.100.0.0/24"
      ];
      privateZone = "home.finnrut.is";
      retention = {
        prometheusTime = "30d";
        prometheusSize = "2GB";
        loki = "168h";
        hardFilesystemCaps = false;
      };
      slo = {
        availability = 0.99;
        window = "7d";
        latencySeconds = {
          internal = 1.0;
          public = 2.0;
        };
      };
      endpoints = {
        grafana = {
          dnsName = "grafana.home.finnrut.is";
          port = 3000;
          exposure = "private";
          homepage = true;
          description = "Metrics, logs, alerts, and SLO drill-down";
          probe = {
            internalPath = "/api/health";
            privatePath = "/api/health";
          };
        };
        homepage = {
          dnsName = "homepage.home.finnrut.is";
          port = 8082;
          exposure = "private";
          homepage = true;
          description = "Private observability front door";
          probe = {
            internalPath = "/";
            privatePath = "/";
          };
        };
        prometheus = {
          port = 9090;
          description = "Metrics store";
        };
        loki = {
          port = 3100;
          description = "System log store";
        };
        alloy = {
          port = 12345;
          description = "System journal collector";
        };
        blackbox = {
          port = 9115;
          description = "Endpoint probe exporter";
        };
        node = {
          port = 9100;
          description = "Link host metrics and systemd state";
        };
        blocky = {
          port = 4000;
          description = "Private DNS metrics";
        };
      };
    };

    configurations.nixos.link.module.assertions = [
      {
        assertion =
          config.observability.trustedClientCidrs == [
            "192.168.5.0/24"
            "192.168.6.0/24"
            "10.100.0.0/24"
          ];
        message = "Phase 1 observability client CIDRs must remain the three explicitly approved networks.";
      }
      {
        assertion = config.hosts.${config.observability.hubHost}.observabilityHub;
        message = "The observability hub must be explicit in the host registry.";
      }
      {
        assertion = config.hosts.link.roles == [ "desktop" ];
        message = "Link remains a desktop; observabilityHub must not reclassify it as a server.";
      }
      {
        assertion = lib.all (
          endpoint:
          lib.elem endpoint.backendAddress [
            "127.0.0.1"
            "::1"
          ]
        ) (lib.attrValues config.observability.endpoints);
        message = "Every observability backend must bind to loopback.";
      }
      {
        assertion =
          config.observability.retention.prometheusTime == "30d"
          && config.observability.retention.prometheusSize == "2GB"
          && config.observability.retention.loki == "168h"
          && !config.observability.retention.hardFilesystemCaps;
        message = "Phase 1 retention must be 30d OR 2GB for Prometheus and 7d for Loki, without hard filesystem caps.";
      }
    ];
  };
}

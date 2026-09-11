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
  nodeTargetType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        scrapeAddress = lib.mkOption {
          type = lib.types.str;
          description = "Transport address Prometheus uses to scrape ${name}.";
        };
        provisionExporter = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether the shared host-telemetry module provisions this node exporter.";
        };
        alertOnDown = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether an unreachable exporter is actionable instead of expected mobility.";
        };
      };
    }
  );
  journalSourceType = lib.types.submodule {
    options.units = lib.mkOption {
      type = lib.types.listOf (lib.types.strMatching "[A-Za-z0-9@_.:-]+\\.service");
      description = "Nonempty NixOS-defined system service units allowed from this logical journal service. Multiple Nix list definitions merge, then source-host assertions reject duplicates. Package- or runtime-generated units are out of scope until they are declared here and exist in systemd.services.";
    };
  };
  journalClientType = lib.types.submodule {
    options = {
      address = lib.mkOption {
        type = lib.types.nullOr (lib.types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+");
        default = null;
        description = "Source IPv4 address allowed at journal ingress; null uses hosts.<host>.homeAddress.";
      };
      username = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9_-]+";
        default = "journal";
        description = "HTTP Basic username for this journal client.";
      };
      passwordSecret = lib.mkOption {
        type = lib.types.strMatching "[A-Za-z0-9_-]+";
        default = "journal-ingress-password";
        description = "Agenix secret basename for this client's plaintext push password; defaults to the first shared credential.";
      };
    };
  };
  privateIpv4Octet = "(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])";
  privateIpv4 = "(10\\.${privateIpv4Octet}\\.${privateIpv4Octet}\\.${privateIpv4Octet}|172\\.(1[6-9]|2[0-9]|3[01])\\.${privateIpv4Octet}\\.${privateIpv4Octet}|192\\.168\\.${privateIpv4Octet}\\.${privateIpv4Octet})";
  isPrivateIpv4 = address: builtins.match privateIpv4 address != null;
  sourceHasUnits =
    sourceServices:
    sourceServices != { } && lib.any (source: source.units != [ ]) (builtins.attrValues sourceServices);
  effectiveClientAddress =
    hostName: client:
    if client.address == null then config.hosts.${hostName}.homeAddress else client.address;
  validIngressFqdn =
    name: builtins.match "([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\\.)+[A-Za-z]{2,}" name != null;
in
{
  # Every provisioned Grafana dashboard, as pure data. Exposing them here is
  # what lets `checks.grafana-dashboards` validate the generated JSON without
  # building a whole NixOS system, and lets both observability modules
  # contribute without one clobbering the other.
  options.flake.grafanaDashboards = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.raw);
    default = { };
    description = "Generated Grafana dashboard definitions, keyed by file name.";
  };

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
      excusals = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              name = lib.mkOption {
                type = lib.types.str;
                description = "Prometheus signal name for this planned-downtime excusal.";
              };
              rationale = lib.mkOption {
                type = lib.types.str;
                description = "Why downtime is expected while this signal is active.";
              };
            };
          }
        );
        default = { };
        description = "Declared planned-downtime excusal signals.";
      };
      latencySeconds = {
        internal = lib.mkOption { type = lib.types.float; };
        public = lib.mkOption { type = lib.types.float; };
      };
    };
    endpoints = lib.mkOption {
      type = lib.types.attrsOf endpointType;
      description = "Typed, Link-only Phase 1 service and probe registry.";
    };
    nodes = lib.mkOption {
      type = lib.types.attrsOf nodeTargetType;
      description = "Node-exporter scrape inventory; dashboard identities come from the matching host registry entries.";
    };
    journal = {
      sources = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf journalSourceType);
        default = { };
        description = "Allowlisted system-journal sources, keyed by host and bounded logical service name.";
      };
      clients = lib.mkOption {
        type = lib.types.attrsOf journalClientType;
        default = { };
        description = "Hosts enrolled to push their allowlisted system journals to the central ingress.";
      };
      ingress = {
        fqdn = lib.mkOption {
          type = lib.types.str;
          default = "loki-journal.home.finnrut.is";
          description = "Dedicated TLS name for journal ingestion.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          default = 8443;
          description = "Dedicated HTTPS port for journal ingestion, never the shared HTTPS port.";
        };
      };
      hub.systemJournal.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Phase B policy switch for a hub whole-system-journal reader; Phase A leaves Link's existing reader untouched.";
      };
    };
  };

  config = {
    observability = {
      hubHost = "link";
      trustedClientCidrs = [
        "192.168.3.0/24"
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
        excusals.gamemode = {
          name = "gamemode";
          rationale = "Nicotine+ is intentionally stopped during gaming, so its downtime is planned.";
        };
        # Class defaults, not universal truths: an application that needs its
        # own budget sets `latencyObjectiveSeconds` in the service-publication
        # registry. Seeded at roughly 3x the measured success-only p95 with a
        # 250ms floor, because 17 of the 19 published endpoints answer in
        # 22-58ms and 3x of that is a threshold too tight to be anything but
        # noise. The previous 1s/2s pair was 6-46x above every endpoint it
        # covered -- sabnzbd could have got 45 times slower without a word.
        latencySeconds = {
          internal = 0.25;
          public = 0.30;
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
      # Only always-on hosts are scrape targets. Zelda and Hylia are laptops
      # that hold a WireGuard address but are off it most of the time, so a
      # target for them is down by design: it can never mean anything, and it
      # sat in every "scrape targets down" count as permanent noise.
      nodes = {
        link.scrapeAddress = config.observability.endpoints.node.backendAddress;
      }
      //
        lib.genAttrs
          [
            "impa"
            "iot"
            "marin"
          ]
          (hostName: {
            scrapeAddress = config.hosts.${hostName}.homeAddress;
            provisionExporter = true;
          });
    };

    configurations.nixos.link.module.assertions = [
      {
        assertion =
          config.observability.trustedClientCidrs == [
            "192.168.3.0/24"
            "192.168.5.0/24"
            "192.168.6.0/24"
            "10.100.0.0/24"
          ];
        message = "Phase 1 observability client CIDRs must remain the four explicitly approved networks.";
      }
      {
        assertion = config.hosts.${config.observability.hubHost}.observabilityHub;
        message = "The observability hub must be explicit in the host registry.";
      }
      {
        assertion = lib.all (hostName: builtins.hasAttr hostName config.hosts) (
          builtins.attrNames config.observability.nodes
        );
        message = "Every observability node must have a matching host registry entry.";
      }
      {
        assertion = config.hosts.link.roles == [ "desktop" ];
        message = "Link remains a desktop; observabilityHub must not reclassify it as a server.";
      }
      {
        assertion = !config.observability.journal.hub.systemJournal.enable;
        message = "Whole-hub journal policy is Phase B; Phase A must not add a second Link journal reader.";
      }
      {
        assertion = lib.all (hostName: hostName != config.observability.hubHost) (
          builtins.attrNames config.observability.journal.sources
        );
        message = "Phase A journal sources must not include the hub, which already has its existing Link journal reader.";
      }
      {
        assertion = lib.all (
          hostName:
          builtins.hasAttr hostName config.hosts
          && config.hosts.${hostName}.isNixOS
          && builtins.hasAttr hostName config.configurations.nixos
        ) (builtins.attrNames config.observability.journal.sources);
        message = "Every journal source must be a configured NixOS/systemd host in the host registry.";
      }
      {
        assertion = lib.all (
          hostName: builtins.hasAttr hostName config.hosts && config.hosts.${hostName}.isNixOS
        ) (builtins.attrNames config.observability.journal.clients);
        message = "Every journal client must be a registered NixOS host.";
      }
      {
        assertion = lib.all (
          hostName:
          builtins.hasAttr hostName config.hosts
          && (
            let
              client = config.observability.journal.clients.${hostName};
              host = config.hosts.${hostName};
              registeredAddresses = builtins.filter (address: address != null) [
                host.homeAddress
                host.iotAddress
                host.wireguard.ipv4Address
              ];
              effectiveAddress = effectiveClientAddress hostName client;
            in
            effectiveAddress != null
            && isPrivateIpv4 effectiveAddress
            && (client.address == null || lib.elem client.address registeredAddresses)
          )
        ) (builtins.attrNames config.observability.journal.clients);
        message = "Every journal client address must be a valid private IPv4; overrides must equal that host's registered home, IoT, or WireGuard address.";
      }
      {
        assertion =
          let
            activeClientNames = builtins.filter (
              hostName:
              hostName != config.observability.hubHost
              && builtins.hasAttr hostName config.hosts
              && builtins.hasAttr hostName config.observability.journal.sources
              && sourceHasUnits config.observability.journal.sources.${hostName}
            ) (builtins.attrNames config.observability.journal.clients);
            addresses = map (
              hostName: effectiveClientAddress hostName config.observability.journal.clients.${hostName}
            ) activeClientNames;
          in
          lib.length addresses == lib.length (lib.unique addresses);
        message = "No two active journal clients may claim the same effective source address.";
      }
      {
        assertion = validIngressFqdn config.observability.journal.ingress.fqdn;
        message = "Journal ingress must use a valid DNS FQDN for its dedicated TLS certificate.";
      }
      {
        assertion =
          config.observability.journal.ingress.port != 443
          && !lib.elem config.observability.journal.ingress.port (
            map (endpoint: endpoint.port) (lib.attrValues config.observability.endpoints)
          );
        message = "Journal ingress must use a dedicated port, not 443 or an observability backend port.";
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

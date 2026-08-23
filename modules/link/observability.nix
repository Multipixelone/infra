{ config, inputs, ... }:
let
  inherit (config) observability;
  inherit (config.flake.meta.owner) email username;
  hub = config.hosts.${observability.hubHost};
  endpointList = observability.endpoints |> builtins.attrValues;
  privateEndpoints = builtins.filter (endpoint: endpoint.exposure == "private") endpointList;
  probedEndpoints = builtins.filter (endpoint: endpoint.probe != null) endpointList;
  internalProbes = map (endpoint: {
    targets = [
      "http://${endpoint.backendAddress}:${toString endpoint.port}${endpoint.probe.internalPath}"
    ];
    labels = {
      endpoint = endpoint.dnsName;
      scope = "internal";
      slo_class = endpoint.probe.sloClass;
    };
  }) probedEndpoints;
  privateProbes = map (endpoint: {
    targets = [ "https://${endpoint.dnsName}${endpoint.probe.privatePath}" ];
    labels = {
      endpoint = endpoint.dnsName;
      scope = "private";
      slo_class = endpoint.probe.sloClass;
    };
  }) (builtins.filter (endpoint: endpoint.probe.privatePath != null) probedEndpoints);

  cloudflareSecret = "${inputs.secrets}/cloudflare/acme-dns01.age";
  grafanaSecret = "${inputs.secrets}/grafana/admin.age";
  hasCloudflareSecret = builtins.pathExists cloudflareSecret;
  hasGrafanaSecret = builtins.pathExists grafanaSecret;
  activationReady = hasCloudflareSecret && hasGrafanaSecret;
  runtimeCloudflareSecret = "/run/agenix/cloudflare-acme-dns01";
  runtimeGrafanaSecret = "/run/agenix/grafana-admin";
  requiredRuntimeSecrets = [
    runtimeCloudflareSecret
    runtimeGrafanaSecret
  ];

  expectedCidrs = [
    "192.168.5.0/24"
    "192.168.6.0/24"
    "10.100.0.0/24"
  ];
in
{
  configurations.nixos.link.module =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (observability.endpoints)
        alloy
        blackbox
        blocky
        grafana
        homepage
        loki
        node
        prometheus
        ;

      yaml = pkgs.formats.yaml { };

      blackboxConfig = yaml.generate "blackbox-observability.yaml" {
        modules = {
          http_internal = {
            prober = "http";
            timeout = "5s";
            http = {
              preferred_ip_protocol = "ip4";
              follow_redirects = true;
            };
          };
          https_private = {
            prober = "http";
            timeout = "8s";
            http = {
              preferred_ip_protocol = "ip4";
              follow_redirects = true;
              fail_if_not_ssl = true;
            };
          };
        };
      };

      mkBlackboxScrape =
        {
          name,
          module,
          targets,
        }:
        {
          job_name = "blackbox-${name}";
          metrics_path = "/probe";
          params.module = [ module ];
          static_configs = targets;
          relabel_configs = [
            {
              source_labels = [ "__address__" ];
              target_label = "__param_target";
            }
            {
              source_labels = [ "__param_target" ];
              target_label = "instance";
            }
            {
              target_label = "__address__";
              replacement = "${blackbox.backendAddress}:${toString blackbox.port}";
            }
          ];
        };

      recordingAndAlertRules = yaml.generate "observability-rules.yaml" {
        groups = [
          {
            name = "observability-slo";
            interval = "1m";
            rules = [
              {
                record = "endpoint:availability_7d";
                expr = "avg_over_time(probe_success[${observability.slo.window}])";
              }
              {
                record = "endpoint:error_budget_remaining_7d";
                expr = "1 - ((1 - endpoint:availability_7d) / ${toString (1.0 - observability.slo.availability)})";
              }
              {
                record = "endpoint:latency_p95_7d";
                expr = "quantile_over_time(0.95, probe_duration_seconds[${observability.slo.window}])";
              }
            ];
          }
          {
            name = "observability-alerts";
            interval = "1m";
            rules = [
              {
                alert = "LinkHostDown";
                expr = ''up{job="link-node"} == 0'';
                for = "5m";
                labels.severity = "critical";
                annotations.summary = "Link host exporter is unreachable";
              }
              {
                alert = "PrometheusScrapeTargetDown";
                expr = ''up{job!~"blackbox-.*|link-node"} == 0'';
                for = "10m";
                labels.severity = "warning";
                annotations.summary = "Prometheus cannot scrape {{ $labels.job }}";
              }
              {
                alert = "EndpointDown";
                expr = "probe_success == 0";
                for = "5m";
                labels.severity = "critical";
                annotations.summary = "{{ $labels.scope }} endpoint {{ $labels.endpoint }} is down";
              }
              {
                alert = "SystemdUnitFailed";
                expr = ''node_systemd_unit_state{state="failed"} == 1'';
                for = "5m";
                labels.severity = "warning";
                annotations.summary = "Systemd unit {{ $labels.name }} is failed";
              }
              {
                alert = "OpenClawGatewayDown";
                expr = "openclaw_gateway_active != 1";
                for = "5m";
                labels.severity = "warning";
                annotations.summary = "OpenClaw gateway service health is degraded";
              }
              {
                alert = "RootDiskPressure";
                expr = ''node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"} < 0.15'';
                for = "10m";
                labels.severity = "warning";
                annotations.summary = "Link root filesystem has less than 15% free (expected to fire initially)";
              }
              {
                alert = "TelemetryStorageGrowth";
                expr = ''predict_linear(node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}[6h], 7 * 24 * 3600) < 0'';
                for = "30m";
                labels.severity = "warning";
                annotations.summary = "Current filesystem growth projects Link root exhaustion within seven days";
              }
              {
                alert = "PrometheusLogicalRetentionNearLimit";
                expr = "prometheus_tsdb_storage_blocks_bytes > 1800000000";
                for = "30m";
                labels.severity = "warning";
                annotations.summary = "Prometheus blocks exceed 1.8 GB; the 2 GB setting is logical retention, not a filesystem quota";
              }
              {
                alert = "ObservabilityTlsExpiring";
                expr = ''probe_ssl_earliest_cert_expiry{scope="private"} - time() < 21 * 24 * 3600'';
                for = "1h";
                labels.severity = "warning";
                annotations.summary = "TLS certificate for {{ $labels.endpoint }} expires within 21 days";
              }
              {
                alert = "InternalSloLatencyHigh";
                expr = ''endpoint:latency_p95_7d{slo_class="internal"} > ${toString observability.slo.latencySeconds.internal}'';
                for = "30m";
                labels.severity = "warning";
                annotations.summary = "Internal endpoint p95 latency exceeds one second";
              }
              {
                alert = "PublicSloLatencyHigh";
                expr = ''endpoint:latency_p95_7d{slo_class="public"} > ${toString observability.slo.latencySeconds.public}'';
                for = "30m";
                labels.severity = "warning";
                annotations.summary = "Public endpoint p95 latency exceeds two seconds";
              }
              {
                alert = "SloErrorBudgetExhausted";
                expr = "endpoint:error_budget_remaining_7d < 0";
                for = "15m";
                labels.severity = "critical";
                annotations.summary = "{{ $labels.endpoint }} exhausted its 99% seven-day error budget";
              }
            ];
          }
        ];
      };

      panel =
        {
          id,
          title,
          expr,
          type ? "timeseries",
          datasource ? "prometheus",
          legend ? "{{instance}}",
          x ? 0,
          y ? 0,
          w ? 12,
          h ? 8,
        }:
        {
          inherit id title type;
          datasource.uid = datasource;
          gridPos = {
            inherit
              x
              y
              w
              h
              ;
          };
          targets = [
            {
              refId = "A";
              inherit expr;
              legendFormat = legend;
            }
          ];
          fieldConfig.defaults = { };
          options = { };
        };

      dashboard =
        {
          uid,
          title,
          panels,
          tags,
          templating ? {
            list = [ ];
          },
        }:
        {
          inherit
            uid
            title
            panels
            tags
            templating
            ;
          schemaVersion = 41;
          version = 1;
          editable = false;
          refresh = "30s";
          time = {
            from = "now-6h";
            to = "now";
          };
        };

      dashboards = {
        "fleet.json" = dashboard {
          uid = "fleet";
          title = "Fleet / Link";
          tags = [
            "provisioned"
            "fleet"
          ];
          panels = [
            (panel {
              id = 1;
              title = "Scrape health";
              expr = "up";
              legend = "{{job}}";
              type = "stat";
              w = 6;
            })
            (panel {
              id = 2;
              title = "Failed systemd units";
              expr = ''sum(node_systemd_unit_state{state="failed"})'';
              type = "stat";
              x = 6;
              w = 6;
            })
            (panel {
              id = 3;
              title = "CPU busy";
              expr = ''100 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100'';
              y = 8;
            })
            (panel {
              id = 4;
              title = "Memory used";
              expr = "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes";
              y = 8;
              x = 12;
            })
            (panel {
              id = 5;
              title = "Root filesystem free";
              expr = ''node_filesystem_avail_bytes{mountpoint="/"}'';
              y = 16;
              w = 24;
            })
          ];
        };
        "service-health.json" = dashboard {
          uid = "service-health";
          title = "Service health";
          tags = [
            "provisioned"
            "health"
          ];
          panels = [
            (panel {
              id = 1;
              title = "Endpoint availability";
              expr = "probe_success";
              legend = "{{scope}} / {{endpoint}}";
              type = "stat";
              w = 8;
            })
            (panel {
              id = 2;
              title = "Probe duration";
              expr = "probe_duration_seconds";
              legend = "{{scope}} / {{endpoint}}";
              x = 8;
              w = 8;
            })
            (panel {
              id = 3;
              title = "TLS days remaining";
              expr = "(probe_ssl_earliest_cert_expiry - time()) / 86400";
              legend = "{{endpoint}}";
              x = 16;
              w = 8;
            })
            (panel {
              id = 4;
              title = "OpenClaw service-only telemetry";
              expr = "openclaw_gateway_active";
              legend = "active";
              type = "stat";
              y = 8;
              w = 8;
            })
            (panel {
              id = 5;
              title = "Service restarts";
              expr = "openclaw_gateway_restarts_total";
              legend = "OpenClaw";
              y = 8;
              x = 8;
              w = 8;
            })
          ];
        };
        "log-explorer.json" = dashboard {
          uid = "log-explorer";
          title = "System log explorer";
          tags = [
            "provisioned"
            "logs"
          ];
          templating.list = [
            {
              name = "unit";
              type = "query";
              datasource.uid = "loki";
              query = "label_values(unit)";
              includeAll = true;
              multi = true;
            }
          ];
          panels = [
            (panel {
              id = 1;
              title = "System journal (user journals excluded, secrets redacted)";
              expr = ''{host="link", unit=~"$unit"}'';
              datasource = "loki";
              type = "logs";
              legend = "";
              w = 24;
              h = 16;
            })
          ];
        };
        "rolling-slo.json" = dashboard {
          uid = "rolling-slo";
          title = "Rolling SLO / error budget";
          tags = [
            "provisioned"
            "slo"
          ];
          panels = [
            (panel {
              id = 1;
              title = "7-day availability (target 99%)";
              expr = "endpoint:availability_7d * 100";
              legend = "{{scope}} / {{endpoint}}";
              y = 0;
              w = 8;
            })
            (panel {
              id = 2;
              title = "7-day error budget remaining";
              expr = "endpoint:error_budget_remaining_7d * 100";
              legend = "{{scope}} / {{endpoint}}";
              x = 8;
              w = 8;
            })
            (panel {
              id = 3;
              title = "7-day p95 latency";
              expr = "endpoint:latency_p95_7d";
              legend = "{{scope}} / {{endpoint}}";
              x = 16;
              w = 8;
            })
          ];
        };
      };

      dashboardDir = pkgs.linkFarm "grafana-observability-dashboards" (
        lib.mapAttrsToList (name: value: {
          inherit name;
          path = pkgs.writeText name (builtins.toJSON value);
        }) dashboards
      );

      alloyConfig = ''
        discovery.relabel "system_journal" {
          targets = []

          rule {
            source_labels = ["__journal__systemd_user_unit"]
            regex         = ".+"
            action        = "drop"
          }

          rule {
            source_labels = ["__journal__systemd_unit"]
            target_label  = "unit"
          }

          rule {
            source_labels = ["__journal__hostname"]
            target_label  = "host"
          }

          rule {
            source_labels = ["__journal_priority_keyword"]
            target_label  = "level"
          }
        }

        loki.source.journal "system" {
          max_age       = "12h"
          relabel_rules = discovery.relabel.system_journal.rules
          forward_to    = [loki.process.redact.receiver]
        }

        loki.process "redact" {
          stage.replace {
            expression = "(?i)(authorization|token|password|secret|api[_-]?key)([\\\"'=:\\x20]+)[^\\x20,;]+"
            replace    = "$1$2[REDACTED]"
          }

          stage.replace {
            expression = "(?i)(bearer\\x20+)[A-Za-z0-9._~+/-]+=*"
            replace    = "$1[REDACTED]"
          }

          stage.replace {
            expression = "bot[0-9]+:[A-Za-z0-9_-]+"
            replace    = "bot[REDACTED]"
          }

          forward_to = [loki.write.local.receiver]
        }

        loki.write "local" {
          endpoint {
            url = "http://${loki.backendAddress}:${toString loki.port}/loki/api/v1/push"
          }
        }
      '';

      openclawMetrics = pkgs.writeShellApplication {
        name = "openclaw-service-metrics";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.systemd
          pkgs.util-linux
        ];
        text = ''
          metrics_dir=/var/lib/prometheus-node-exporter-text-files
          metrics_tmp="$metrics_dir/openclaw.prom.tmp"
          metrics_out="$metrics_dir/openclaw.prom"
          user_runtime=/run/user/$(id -u ${lib.escapeShellArg username})

          show_unit() {
            runuser -u ${lib.escapeShellArg username} -- env \
              XDG_RUNTIME_DIR="$user_runtime" \
              DBUS_SESSION_BUS_ADDRESS="unix:path=$user_runtime/bus" \
              systemctl --user show openclaw-gateway.service "$@" 2>/dev/null
          }

          active=0
          failed=0
          if [ "$(show_unit --property=ActiveState --value || true)" = active ]; then active=1; fi
          if [ "$(show_unit --property=ActiveState --value || true)" = failed ]; then failed=1; fi
          restarts="$(show_unit --property=NRestarts --value || true)"
          memory="$(show_unit --property=MemoryCurrent --value || true)"
          cpu_ns="$(show_unit --property=CPUUsageNSec --value || true)"

          case "$restarts" in (*[!0-9]*|"") restarts=0;; esac
          case "$memory" in (*[!0-9]*|"") memory=0;; esac
          case "$cpu_ns" in (*[!0-9]*|"") cpu_ns=0;; esac

          {
            echo '# HELP openclaw_gateway_active Whether the OpenClaw gateway user service is active.'
            echo '# TYPE openclaw_gateway_active gauge'
            echo "openclaw_gateway_active $active"
            echo '# HELP openclaw_gateway_failed Whether the OpenClaw gateway user service is failed.'
            echo '# TYPE openclaw_gateway_failed gauge'
            echo "openclaw_gateway_failed $failed"
            echo '# HELP openclaw_gateway_restarts_total Systemd restart count for the OpenClaw gateway.'
            echo '# TYPE openclaw_gateway_restarts_total counter'
            echo "openclaw_gateway_restarts_total $restarts"
            echo '# HELP openclaw_gateway_memory_bytes Current OpenClaw gateway memory use.'
            echo '# TYPE openclaw_gateway_memory_bytes gauge'
            echo "openclaw_gateway_memory_bytes $memory"
            echo '# HELP openclaw_gateway_cpu_seconds_total OpenClaw gateway CPU use.'
            echo '# TYPE openclaw_gateway_cpu_seconds_total counter'
            awk "BEGIN { print \"openclaw_gateway_cpu_seconds_total \" $cpu_ns / 1000000000 }"
          } > "$metrics_tmp"
          chmod 0644 "$metrics_tmp"
          mv "$metrics_tmp" "$metrics_out"
        '';
      };

      mcpGrafana = pkgs.writeShellApplication {
        name = "mcp-grafana-read-only";
        runtimeInputs = [ pkgs.mcp-grafana ];
        text = ''
          set -a
          # Contract: shell-compatible GRAFANA_ADMIN_PASSWORD and
          # GRAFANA_SECRET_KEY assignments. Nothing is copied to the store.
          if [ ! -r ${runtimeGrafanaSecret} ]; then
            echo "mcp-grafana is gated until ${runtimeGrafanaSecret} exists" >&2
            exit 1
          fi
          source ${runtimeGrafanaSecret}
          set +a
          export GRAFANA_URL="http://${grafana.backendAddress}:${toString grafana.port}"
          export GRAFANA_USERNAME=admin
          export GRAFANA_PASSWORD="$GRAFANA_ADMIN_PASSWORD"
          unset GRAFANA_ADMIN_PASSWORD GRAFANA_SECRET_KEY
          exec mcp-grafana \
            --disable-write \
            --enabled-tools=prometheus,loki
        '';
      };

      nginxAcl =
        lib.concatMapStrings (cidr: "allow ${cidr};\n") observability.trustedClientCidrs + "deny all;";
      nginxListen = [
        {
          addr = hub.homeAddress;
          port = 443;
          ssl = true;
        }
        {
          addr = hub.wireguard.ipv4Address;
          port = 443;
          ssl = true;
        }
      ];

      protectedTcpPorts = [ 53 ] ++ lib.optionals activationReady [ 443 ];
      firewallPortList = lib.concatMapStringsSep "," toString protectedTcpPorts;
      firewallAccepts = lib.concatMapStrings (
        cidr: "iptables -w -A nixos-observability -s ${cidr} -j nixos-fw-accept\n"
      ) observability.trustedClientCidrs;

      telegramContactRouted = false;
      mcpArgs = [
        "--disable-write"
        "--enabled-tools=prometheus,loki"
      ];
    in
    {
      assertions = [
        {
          assertion = observability.hubHost == "link" && hub.observabilityHub;
          message = "Phase 1 is Link-only and Link must be the explicit observability hub.";
        }
        {
          assertion = observability.trustedClientCidrs == expectedCidrs;
          message = "DNS, firewall, and nginx must share only the three approved CIDRs.";
        }
        {
          assertion = lib.all (endpoint: endpoint.backendAddress == "127.0.0.1") endpointList;
          message = "All Phase 1 application backends must be IPv4 loopback-only.";
        }
        {
          assertion = !observability.enablePublicDns && !observability.enableTunnel;
          message = "Public DNS, Cloudflare Tunnel, and public ingress are forbidden for Phase 1.";
        }
        {
          assertion = !telegramContactRouted;
          message = "The Telegram contact point must remain unrouted during the seven-day review.";
        }
        {
          assertion =
            observability.retention.prometheusTime == "30d"
            && observability.retention.prometheusSize == "2GB"
            && observability.retention.loki == "168h"
            && !observability.retention.hardFilesystemCaps;
          message = "Retention settings are application-level limits, not hard filesystem quotas.";
        }
        {
          assertion =
            lib.elem "--disable-write" mcpArgs && lib.elem "--enabled-tools=prometheus,loki" mcpArgs;
          message = "mcp-grafana must expose only read-only, unrestricted-scope PromQL/LogQL tools.";
        }
        {
          assertion =
            !lib.hasInfix "/home/${username}/.openclaw" alloyConfig
            && lib.hasInfix "__journal__systemd_user_unit" alloyConfig
            && lib.hasInfix ''action        = "drop"'' alloyConfig;
          message = "Alloy must exclude user journals and raw OpenClaw payloads; only service metrics are allowed.";
        }
        {
          assertion =
            !config.services.grafana.settings."auth.anonymous".enabled
            && !config.services.grafana.settings.users.allow_sign_up
            && !config.services.grafana.settings.auth.disable_login_form;
          message = "Grafana must use local admin auth with anonymous access and signup disabled.";
        }
        {
          assertion = config.services.grafana.provision.alerting.policies.settings == null;
          message = "The Telegram contact point must have no notification policy during review.";
        }
        {
          assertion =
            config.systemd.services.grafana.unitConfig.ConditionPathExists == requiredRuntimeSecrets
            && config.systemd.services.nginx.unitConfig.ConditionPathExists == requiredRuntimeSecrets;
          message = "Grafana and HTTPS must remain gated on both runtime secrets.";
        }
        {
          assertion =
            config.services.prometheus.listenAddress == "127.0.0.1"
            && config.services.loki.configuration.server.http_listen_address == "127.0.0.1"
            && config.services.homepage-dashboard.openFirewall == false;
          message = "Prometheus, Loki, and Homepage must not expose their application ports.";
        }
      ];

      networking.firewall = {
        extraCommands = ''
          iptables -w -N nixos-observability 2>/dev/null || iptables -w -F nixos-observability
          ${firewallAccepts}
          iptables -w -A nixos-observability -j nixos-fw-refuse
          iptables -w -I nixos-fw 1 -p tcp -m multiport --dports ${firewallPortList} -j nixos-observability
          iptables -w -I nixos-fw 1 -p udp --dport 53 -j nixos-observability
        '';
        extraStopCommands = ''
          iptables -w -D nixos-fw -p tcp -m multiport --dports ${firewallPortList} -j nixos-observability 2>/dev/null || true
          iptables -w -D nixos-fw -p udp --dport 53 -j nixos-observability 2>/dev/null || true
          iptables -w -F nixos-observability 2>/dev/null || true
          iptables -w -X nixos-observability 2>/dev/null || true
        '';
      };

      age.secrets = lib.mkMerge [
        (lib.mkIf hasCloudflareSecret {
          "cloudflare-acme-dns01" = {
            file = cloudflareSecret;
            owner = "root";
            group = "root";
            mode = "0400";
          };
        })
        (lib.mkIf hasGrafanaSecret {
          "grafana-admin" = {
            file = grafanaSecret;
            owner = username;
            group = "users";
            mode = "0400";
          };
        })
      ];

      security.acme = {
        acceptTerms = true;
        defaults.email = email;
        certs."grafana.home.finnrut.is" = {
          domain = "grafana.home.finnrut.is";
          extraDomainNames = [ "homepage.home.finnrut.is" ];
          dnsProvider = "cloudflare";
          environmentFile = runtimeCloudflareSecret;
          group = "nginx";
        };
      };

      services.nginx = {
        enable = true;
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
        virtualHosts = {
          "grafana.home.finnrut.is" = {
            listen = nginxListen;
            onlySSL = true;
            useACMEHost = "grafana.home.finnrut.is";
            locations."/" = {
              proxyPass = "http://${grafana.backendAddress}:${toString grafana.port}";
              proxyWebsockets = true;
              extraConfig = nginxAcl;
            };
          };
          "homepage.home.finnrut.is" = {
            listen = nginxListen;
            onlySSL = true;
            useACMEHost = "grafana.home.finnrut.is";
            locations."/" = {
              proxyPass = "http://${homepage.backendAddress}:${toString homepage.port}";
              proxyWebsockets = true;
              extraConfig = nginxAcl;
            };
          };
        };
      };

      services.grafana = {
        enable = true;
        openFirewall = false;
        settings = {
          server = {
            http_addr = grafana.backendAddress;
            http_port = grafana.port;
            domain = grafana.dnsName;
            root_url = "https://${grafana.dnsName}/";
            enforce_domain = true;
          };
          analytics = {
            reporting_enabled = false;
            check_for_updates = false;
          };
          security = {
            admin_user = "admin";
            admin_password = "$__env{GRAFANA_ADMIN_PASSWORD}";
            secret_key = "$__env{GRAFANA_SECRET_KEY}";
            disable_gravatar = true;
            cookie_secure = true;
          };
          users = {
            allow_sign_up = false;
            allow_org_create = false;
          };
          "auth.anonymous".enabled = false;
          auth.disable_login_form = false;
        };
        provision = {
          enable = true;
          datasources.settings = {
            apiVersion = 1;
            prune = true;
            datasources = [
              {
                name = "Prometheus";
                uid = "prometheus";
                type = "prometheus";
                access = "proxy";
                url = "http://${prometheus.backendAddress}:${toString prometheus.port}";
                isDefault = true;
                editable = false;
              }
              {
                name = "Loki";
                uid = "loki";
                type = "loki";
                access = "proxy";
                url = "http://${loki.backendAddress}:${toString loki.port}";
                editable = false;
              }
            ];
          };
          dashboards.settings = {
            apiVersion = 1;
            providers = [
              {
                name = "Phase 1 observability";
                type = "file";
                disableDeletion = true;
                allowUiUpdates = false;
                updateIntervalSeconds = 60;
                options.path = dashboardDir;
              }
            ];
          };
          alerting.contactPoints.settings = {
            apiVersion = 1;
            contactPoints = [
              {
                orgId = 1;
                name = "Telegram (disabled pending seven-day review)";
                receivers = [
                  {
                    uid = "telegram-disabled-review";
                    type = "telegram";
                    disableResolveMessage = true;
                    settings.chatid = "$TELEGRAM_CHAT_ID";
                    secureSettings.bottoken = "$TELEGRAM_BOT_TOKEN";
                  }
                ];
              }
            ];
          };
        };
      };

      systemd.services.grafana.serviceConfig.EnvironmentFile = [
        runtimeGrafanaSecret
        config.age.secrets."telegram-deadman".path
      ];

      services.prometheus = {
        enable = true;
        listenAddress = prometheus.backendAddress;
        inherit (prometheus) port;
        retentionTime = observability.retention.prometheusTime;
        extraFlags = [ "--storage.tsdb.retention.size=${observability.retention.prometheusSize}" ];
        ruleFiles = [ recordingAndAlertRules ];
        scrapeConfigs = [
          {
            job_name = "link-node";
            static_configs = [ { targets = [ "${node.backendAddress}:${toString node.port}" ]; } ];
          }
          {
            job_name = "prometheus";
            static_configs = [ { targets = [ "${prometheus.backendAddress}:${toString prometheus.port}" ]; } ];
          }
          {
            job_name = "loki";
            static_configs = [ { targets = [ "${loki.backendAddress}:${toString loki.port}" ]; } ];
          }
          {
            job_name = "alloy";
            static_configs = [ { targets = [ "${alloy.backendAddress}:${toString alloy.port}" ]; } ];
          }
          {
            job_name = "blackbox";
            static_configs = [ { targets = [ "${blackbox.backendAddress}:${toString blackbox.port}" ]; } ];
          }
          {
            job_name = "blocky";
            static_configs = [ { targets = [ "${blocky.backendAddress}:${toString blocky.port}" ]; } ];
          }
          (mkBlackboxScrape {
            name = "internal";
            module = "http_internal";
            targets = internalProbes;
          })
          (mkBlackboxScrape {
            name = "private";
            module = "https_private";
            targets = privateProbes;
          })
        ];
        exporters = {
          node = {
            enable = true;
            listenAddress = node.backendAddress;
            inherit (node) port;
            enabledCollectors = [ "systemd" ];
            extraFlags = [ "--collector.textfile.directory=/var/lib/prometheus-node-exporter-text-files" ];
          };
          blackbox = {
            enable = true;
            listenAddress = blackbox.backendAddress;
            inherit (blackbox) port;
            configFile = blackboxConfig;
          };
        };
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/prometheus-node-exporter-text-files 0755 root root - -"
      ];

      systemd.services.openclaw-service-metrics = {
        description = "Export health/resource telemetry for the OpenClaw gateway without payloads";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe openclawMetrics;
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ "/var/lib/prometheus-node-exporter-text-files" ];
        };
      };

      systemd.timers.openclaw-service-metrics = {
        description = "Refresh OpenClaw service-only Prometheus metrics";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitActiveSec = "1m";
          Unit = "openclaw-service-metrics.service";
        };
      };

      services.loki = {
        enable = true;
        configuration = {
          auth_enabled = false;
          server = {
            http_listen_address = loki.backendAddress;
            http_listen_port = loki.port;
            grpc_listen_address = loki.backendAddress;
          };
          common = {
            path_prefix = "/var/lib/loki";
            replication_factor = 1;
            ring.kvstore.store = "inmemory";
          };
          schema_config.configs = [
            {
              from = "2024-01-01";
              store = "tsdb";
              object_store = "filesystem";
              schema = "v13";
              index = {
                prefix = "index_";
                period = "24h";
              };
            }
          ];
          storage_config.filesystem.directory = "/var/lib/loki/chunks";
          compactor = {
            working_directory = "/var/lib/loki/compactor";
            retention_enabled = true;
            delete_request_store = "filesystem";
          };
          limits_config = {
            retention_period = observability.retention.loki;
            allow_structured_metadata = true;
          };
        };
      };

      services.alloy = {
        enable = true;
        configPath = "/etc/alloy/config.alloy";
        extraFlags = [
          "--server.http.listen-addr=${alloy.backendAddress}:${toString alloy.port}"
          "--disable-reporting"
        ];
      };
      environment.etc."alloy/config.alloy" = {
        text = alloyConfig;
        mode = "0444";
      };

      services.homepage-dashboard = {
        enable = true;
        openFirewall = false;
        listenPort = homepage.port;
        allowedHosts = lib.concatStringsSep "," [
          "${homepage.dnsName}"
          "${homepage.dnsName}:443"
          "localhost:${toString homepage.port}"
          "127.0.0.1:${toString homepage.port}"
        ];
        settings = {
          title = "Link observability";
          headerStyle = "clean";
          statusStyle = "dot";
          hideVersion = true;
        };
        services = [
          {
            Observability =
              map
                (endpoint: {
                  "${endpoint.description}" = {
                    href = "https://${endpoint.dnsName}";
                    inherit (endpoint) description;
                  };
                })
                (
                  builtins.filter (
                    endpoint: endpoint.homepage && endpoint.dnsName != homepage.dnsName
                  ) privateEndpoints
                );
          }
        ];
        widgets = [
          {
            resources = {
              cpu = true;
              memory = true;
              disk = "/";
            };
          }
        ];
      };
      systemd.services.homepage-dashboard.environment.HOSTNAME = homepage.backendAddress;

      home-manager.users.${username} = {
        home.packages = [ mcpGrafana ];
        mcp-servers.settings.servers.grafana-local = {
          command = lib.getExe mcpGrafana;
          args = [ ];
        };
      };

      # Generated configuration stays in the closure and is evaluated before
      # secrets exist, but runtime activation is an AND gate on both agenix
      # paths. No unit below can start early.
      systemd.services."acme-grafana.home.finnrut.is".unitConfig.ConditionPathExists =
        requiredRuntimeSecrets;
      systemd.services.alloy.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
      systemd.services.grafana.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
      systemd.services.homepage-dashboard.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
      systemd.services.loki.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
      systemd.services.nginx.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
      systemd.services.openclaw-service-metrics.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
      systemd.services.prometheus.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
      systemd.services.prometheus-blackbox-exporter.unitConfig.ConditionPathExists =
        requiredRuntimeSecrets;
      systemd.services.prometheus-node-exporter.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
    };
}

{
  config,
  inputs,
  lib,
  ...
}:
let
  inherit (config) observability;
  hostRegistry = config.hosts;
  # Named `viz`, not `grafana`: the module's inner `let` already binds
  # `grafana` to the endpoint registry entry.
  viz = import ../../lib/grafana.nix { inherit lib; };
  inherit (config.flake.meta.owner) email username;
  serviceInventory = config.flake.servicePublicationInventory;
  localCutover = config.servicePublication.rollout.enableLocalCutover;
  grafanaCanonical = serviceInventory.applications.grafana.canonical;
  homepageCanonical = serviceInventory.applications.homepage.canonical;
  # Each of these servers binds a single address, so it has to be the one the
  # generated proxy dials. Reading it back from the inventory means a proxy
  # move (link -> impa) flips loopback to the LAN address on its own, instead
  # of binding the LAN address unconditionally and 502ing while link is still
  # its own proxy.
  homepageBindAddress = serviceInventory.routes."homepage/root".backendAddress;
  grafanaBindAddress = serviceInventory.routes."grafana/root".backendAddress;
  # Homepage tiles come from the service-publication registry, so every
  # application registered there is listed automatically. Links use the
  # canonical hostname (blocky resolves it for every trusted client); the
  # status dot probes the backend health target directly because Homepage
  # checks server-side from link, which must not depend on its own proxy or
  # DNS path to report a backend down.
  homepageServiceGroups =
    let
      listed = lib.filterAttrs (
        _: application: application.homepage.enable
      ) config.servicePublication.applications;
      entries = lib.mapAttrsToList (
        name: application:
        let
          routes = builtins.filter (route: route.application == name) (
            builtins.attrValues serviceInventory.routes
          );
          rootRoutes = builtins.filter (route: route.pathPrefix == "/") routes;
          monitorRoute = builtins.head (if rootRoutes == [ ] then routes else rootRoutes);
        in
        {
          inherit (application) homepage;
          displayName =
            if application.homepage.name != null then application.homepage.name else lib.toSentenceCase name;
          entry = {
            href = "https://${serviceInventory.applications.${name}.canonical}";
            siteMonitor = "${monitorRoute.backend.scheme}://${monitorRoute.backendAddress}:${toString monitorRoute.backend.port}${monitorRoute.health.path}";
          }
          // lib.optionalAttrs (application.homepage.description != null) {
            inherit (application.homepage) description;
          }
          // lib.optionalAttrs (application.homepage.icon != null) {
            inherit (application.homepage) icon;
          };
        }
      ) listed;
    in
    lib.mapAttrsToList (group: groupEntries: {
      ${group} = map (item: { ${item.displayName} = item.entry; }) (
        lib.sortOn (item: item.displayName) groupEntries
      );
    }) (builtins.groupBy (item: item.homepage.group) entries);
  publicationSite =
    config.servicePublication.sites.${config.servicePublication.applications.grafana.site};
  effectiveTrustedCidrs =
    if localCutover then publicationSite.trustedClientCidrs else observability.trustedClientCidrs;
  hub = config.hosts.${observability.hubHost};
  nodeEntries = lib.mapAttrsToList (
    registryName: target:
    target
    // {
      hostName = hostRegistry.${registryName}.hostName;
    }
  ) observability.nodes;
  nodeHostNames = map (node: node.hostName) nodeEntries;
  requiredNodeHostNames = map (node: node.hostName) (
    builtins.filter (node: node.alertOnDown) nodeEntries
  );
  regexFor = values: lib.concatStringsSep "|" (map lib.escapeRegex values);
  nodeHostRegex = regexFor nodeHostNames;
  nodeJobRegex = "(${nodeHostRegex})-node";
  requiredNodeHostRegex = regexFor requiredNodeHostNames;
  requiredNodeJobRegex = "(${requiredNodeHostRegex})-node";
  resolverEntries =
    lib.mapAttrsToList
      (registryName: publicationHost: {
        inherit registryName;
        hostName = hostRegistry.${registryName}.hostName;
        inherit (publicationHost.addresses) lan;
      })
      (
        lib.filterAttrs (
          _: publicationHost:
          publicationHost.site == config.servicePublication.applications.grafana.site
          && publicationHost.capabilities.internalDns
        ) config.servicePublication.hosts
      );
  resolverHostRegex = regexFor (map (resolver: resolver.hostName) resolverEntries);
  endpointList = observability.endpoints |> builtins.attrValues;
  privateEndpoints = builtins.filter (endpoint: endpoint.exposure == "private") endpointList;
  probedEndpoints = builtins.filter (endpoint: endpoint.probe != null) endpointList;
  # An application published to the internet is held to the public latency
  # objective; everything else to the internal one. Both cutover branches used
  # to hardcode "internal", which is why `PublicSloLatencyHigh` could never
  # fire no matter how slow a public endpoint got.
  sloClassFor =
    application:
    if (serviceInventory.applications.${application}.public or false) then "public" else "internal";
  # After the service-publication cutover, its generated internal HTTPS probe
  # is the user-visible health check. Keeping the old direct-backend probe as
  # well made every logical endpoint appear once as internal and once as
  # private, and counted both copies independently in the SLO.
  internalProbeModule = if localCutover then "https_internal" else "http_internal";
  internalProbes =
    if localCutover then
      map (probe: {
        targets = [ "https://${probe.canonical}${probe.path}" ];
        labels = {
          endpoint = probe.canonical;
          scope = "internal";
          slo_class = sloClassFor serviceInventory.routes.${probe.routeKey}.application;
          resolver = probe.resolverHost;
        };
      }) serviceInventory.internalProbes
    else
      map (endpoint: {
        targets = [
          "http://${endpoint.backendAddress}:${toString endpoint.port}${endpoint.probe.internalPath}"
        ];
        labels = {
          endpoint = endpoint.dnsName;
          scope = "internal";
          slo_class = endpoint.probe.sloClass;
        };
      }) probedEndpoints;
  privateProbes =
    if localCutover then
      [ ]
    else
      map (endpoint: {
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

  # Loopback interfaces and container/VM bridges carry no signal worth a
  # panel, and their names would crowd out the one physical NIC.
  realInterfaces = ''device!~"lo|veth.*|podman.*|br-.*|virbr.*|docker.*|tailscale.*|wg.*|zt.*"'';
  realFilesystems = ''fstype!~"tmpfs|ramfs|overlay|nsfs|squashfs|fuse.*|autofs"'';
  # Partitions duplicate their parent disk's counters.
  wholeDisks = ''device=~"nvme[0-9]+n[0-9]+|sd[a-z]|mmcblk[0-9]+"'';
  sloTargetPercent = observability.slo.availability * 100;
  # Only the generated service-publication probes represent user-facing
  # endpoints. Other blackbox jobs may also carry an `endpoint` label (for
  # example the Tautulli exporter's readiness check), but folding those into
  # the rolling SLO makes an observability component consume a service's
  # availability budget.
  sloProbeSelector = ''job=~"blackbox-internal|blackbox-private",endpoint!=""'';
  effectiveProbeSuccess = "((probe_success{${sloProbeSelector}} and on (job, instance) (up{${sloProbeSelector}} == 1)) or up{${sloProbeSelector}})";
  endpointProbeSuccess = "min by (endpoint, slo_class) (${effectiveProbeSuccess})";
  sloWindowEligibility = "min by (endpoint, slo_class) ((probe_success{${sloProbeSelector}} offset ${observability.slo.window}) or (up{${sloProbeSelector}} offset ${observability.slo.window}))";
  # The instance matcher also excludes pre-normalization history whose label
  # was an IP address. It is better to show a gap across this one-time schema
  # migration than leak transport addresses back into a host legend.
  hostJobSelector = ''job=~"${nodeJobRegex}",instance=~"${nodeHostRegex}"'';
  requiredNodeJobSelector = ''job=~"${requiredNodeJobRegex}",instance=~"${requiredNodeHostRegex}"'';
  # Prometheus retains `up = 0` when a configured exporter cannot be scraped,
  # but a missing target would otherwise disappear from a table entirely.
  # Generate a -1 scaffold from the same node inventory as the scrape jobs: a
  # real 0/1 wins under max(), while an absent target remains as NO DATA.
  hostExporterScaffold = lib.concatMapStringsSep "\n      or " (
    hostName: ''label_replace(vector(-1), "instance", "${hostName}", "", "")''
  ) nodeHostNames;
  hostExporterStatus = ''
    max by (instance) (
      up{${hostJobSelector}}
      or ${hostExporterScaffold}
    )
  '';
  hostStatusMappings = [
    {
      type = "value";
      options = {
        "-1" = {
          text = "NO DATA";
          color = "gray";
          index = 2;
        };
        "0" = {
          text = "DOWN";
          color = "red";
          index = 1;
        };
        "1" = {
          text = "UP";
          color = "green";
          index = 0;
        };
      };
    }
    {
      type = "special";
      options = {
        match = "null+nan";
        result = {
          text = "NO DATA";
          color = "gray";
          index = 3;
        };
      };
    }
  ];

  dashboards = {
    "home.json" = viz.dashboard {
      uid = "home";
      title = "Home";
      tags = [
        "provisioned"
        "home"
      ];
      description = "One screen for the whole stack, and the index to everything else.";
      refresh = "1m";
      preload = true;
      rows = [
        [ (viz.row "Is anything wrong?") ]
        [
          (viz.panel {
            title = "Alerts firing";
            type = "stat";
            w = 5;
            h = 6;
            expr = ''count(ALERTS{alertstate="firing"}) or vector(0)'';
            unit = viz.units.none;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 1;
              }
              {
                color = "red";
                value = 5;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "area";
            };
            links = [
              (viz.dataLink {
                title = "Open the alerts dashboard";
                url = "/d/alerts/alerts?\${__url_time_range}";
              })
            ];
          })
          (viz.panel {
            title = "Endpoints up";
            type = "gauge";
            w = 5;
            h = 6;
            expr = ''sum(min by (endpoint) (probe_success{endpoint!=""})) / count(min by (endpoint) (probe_success{endpoint!=""}))'';
            unit = viz.units.percentunit;
            min = 0;
            max = 1;
            decimals = 2;
            thresholds = [
              { color = "red"; }
              {
                color = "orange";
                value = 0.95;
              }
              {
                color = "green";
                value = 1;
              }
            ];
            options = viz.gaugePresets.segmented;
          })
          (viz.panel {
            title = "Scrape targets down";
            type = "stat";
            w = 4;
            h = 6;
            expr = "count(up == 0) or vector(0)";
            unit = viz.units.none;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 1;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
          (viz.panel {
            title = "Failed units";
            type = "stat";
            w = 4;
            h = 6;
            expr = ''max by (instance) (node_systemd_units{${hostJobSelector},state="failed"})'';
            legend = "{{instance}}";
            unit = viz.units.none;
            decimals = 0;
            noValue = "0";
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 1;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
          (viz.panel {
            title = "Logs flowing";
            type = "stat";
            w = 6;
            h = 6;
            description = "Lines per second reaching Loki. A flat zero means the write path is broken, not that the box is quiet.";
            expr = ''sum(rate(loki_write_sent_entries_total{instance="link"}[$__rate_interval]))'';
            unit = viz.units.ops;
            decimals = 2;
            thresholds = [
              { color = "red"; }
              {
                color = "green";
                value = 0.001;
              }
            ];
            options.colorMode = "background";
          })
        ]
        [ (viz.row "Host") ]
        [
          (viz.panel {
            title = "CPU";
            type = "gauge";
            w = 4;
            h = 7;
            expr = ''100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{${hostJobSelector},mode="idle"}[$__rate_interval])))'';
            legend = "{{instance}}";
            unit = viz.units.percent;
            min = 0;
            max = 100;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 85;
              }
              {
                color = "red";
                value = 95;
              }
            ];
            options = viz.gaugePresets.segmented;
          })
          (viz.panel {
            title = "Memory";
            type = "gauge";
            w = 4;
            h = 7;
            expr = "100 * clamp_min(1 - (max by (instance) (node_memory_MemAvailable_bytes{${hostJobSelector}}) / max by (instance) (node_memory_MemTotal_bytes{${hostJobSelector}})), 0)";
            legend = "{{instance}}";
            unit = viz.units.percent;
            min = 0;
            max = 100;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 80;
              }
              {
                color = "red";
                value = 90;
              }
            ];
            options = viz.gaugePresets.segmented;
          })
          (viz.panel {
            title = "Root disk";
            type = "gauge";
            w = 4;
            h = 7;
            expr = ''100 * max by (instance) (1 - (node_filesystem_avail_bytes{${hostJobSelector},mountpoint="/"} / node_filesystem_size_bytes{${hostJobSelector},mountpoint="/"}))'';
            legend = "{{instance}}";
            unit = viz.units.percent;
            min = 0;
            max = 100;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 80;
              }
              {
                color = "red";
                value = 90;
              }
            ];
            options = viz.gaugePresets.segmented;
          })
          (viz.panel {
            title = "Load and uptime";
            type = "stat";
            w = 6;
            h = 7;
            targets = [
              {
                expr = "max by (instance) (node_load1{${hostJobSelector}})";
                legend = "{{instance}} load 1m";
              }
              {
                expr = "count by (instance) (count by (instance, cpu) (node_cpu_seconds_total{${hostJobSelector}}))";
                legend = "{{instance}} cores";
              }
              {
                expr = "max by (instance) (node_time_seconds{${hostJobSelector}} - node_boot_time_seconds{${hostJobSelector}})";
                legend = "{{instance}} uptime";
              }
            ];
            unit = viz.units.short;
            decimals = 1;
            thresholds = [ { color = "text"; } ];
            options = {
              graphMode = "none";
              colorMode = "none";
              textMode = "value_and_name";
              orientation = "horizontal";
            };
            overrides = [
              (viz.overrideByRegexp "/ uptime$/" [
                {
                  id = "unit";
                  value = viz.units.duration;
                }
              ])
            ];
          })
          (viz.panel {
            title = "DNS and media";
            type = "stat";
            w = 6;
            h = 7;
            targets = [
              {
                expr = "sum(rate(blocky_query_total[$__rate_interval]))";
                legend = "DNS q/s";
              }
              {
                expr = "media:plex_streams or vector(0)";
                legend = "Plex streams";
              }
              {
                expr = "media:arr_queue_items or vector(0)";
                legend = "Downloads queued";
              }
            ];
            unit = viz.units.short;
            decimals = 1;
            thresholds = [ { color = "text"; } ];
            options = {
              graphMode = "none";
              colorMode = "none";
              textMode = "value_and_name";
              orientation = "horizontal";
            };
          })
        ]
        [ (viz.row "Everything else") ]
        [
          (viz.panel {
            title = "Dashboards";
            type = "dashlist";
            w = 8;
            h = 10;
            options.tags = [ "provisioned" ];
          })
          (viz.panel {
            title = "Endpoint availability";
            type = "state-timeline";
            w = 16;
            h = 10;
            expr = ''min by (endpoint) (probe_success{endpoint!=""})'';
            legend = "{{endpoint}}";
            mappings = viz.boolMapping { };
            options = {
              perPage = 40;
              legend.showLegend = false;
            };
          })
        ]
      ];
    };

    "alerts.json" = viz.dashboard {
      uid = "alerts";
      title = "Alerts";
      tags = [
        "provisioned"
        "alerts"
      ];
      description = "Prometheus-side alerting rules. There is no Alertmanager: rules evaluate in Prometheus and surface here and as the ALERTS series.";
      from = "now-24h";
      rows = [
        [ (viz.row "Right now") ]
        [
          (viz.panel {
            title = "Firing";
            type = "stat";
            w = 4;
            h = 6;
            # `or vector(0)` so a healthy fleet reads "0" rather than "No data".
            expr = ''count(ALERTS{alertstate="firing"}) or vector(0)'';
            unit = viz.units.none;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 1;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "area";
            };
          })
          (viz.panel {
            title = "Critical";
            type = "stat";
            w = 4;
            h = 6;
            expr = ''sum(ALERTS{alertstate="firing",severity="critical"}) or vector(0)'';
            unit = viz.units.none;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 1;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
          (viz.panel {
            title = "Warning";
            type = "stat";
            w = 4;
            h = 6;
            expr = ''sum(ALERTS{alertstate="firing",severity="warning"}) or vector(0)'';
            unit = viz.units.none;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 1;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
          (viz.panel {
            title = "Pending";
            type = "stat";
            w = 4;
            h = 6;
            description = "Alerts whose condition is true but whose `for` window has not elapsed yet.";
            expr = ''count(ALERTS{alertstate="pending"}) or vector(0)'';
            unit = viz.units.none;
            decimals = 0;
            thresholds = [
              { color = "text"; }
              {
                color = "orange";
                value = 1;
              }
            ];
            options.graphMode = "none";
          })
          (viz.panel {
            title = "Longest active";
            type = "stat";
            w = 8;
            h = 6;
            # ALERTS_FOR_STATE carries no `alertstate` label, so an unqualified
            # `and` matches nothing at all; the label must be ignored.
            expr = ''max(time() - (ALERTS_FOR_STATE and ignoring(alertstate) ALERTS{alertstate="firing"})) or vector(0)'';
            unit = viz.units.duration;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 3600;
              }
              {
                color = "red";
                value = 86400;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
        ]
        [
          (viz.panel {
            title = "Active alerts";
            type = "table";
            w = 24;
            h = 11;
            description = "Duration counts from when the alert became pending, so it includes each rule's `for` window.";
            targets = [
              {
                expr = ''time() - (ALERTS_FOR_STATE and ignoring(alertstate) ALERTS{alertstate="firing"})'';
                instant = true;
                format = "table";
              }
            ];
            noValue = "Nothing is firing.";
            transformations = [
              {
                id = "organize";
                options = {
                  excludeByName = {
                    Time = true;
                    __name__ = true;
                    fstype = true;
                    device = true;
                    mountpoint = true;
                    alertstate = true;
                  };
                  indexByName = {
                    severity = 0;
                    alertname = 1;
                    endpoint = 2;
                    instance = 3;
                    Value = 4;
                  };
                  renameByName = {
                    alertname = "Alert";
                    severity = "Severity";
                    job = "Service";
                    instance = "Host";
                    endpoint = "Endpoint";
                    resolver = "Resolver";
                    scope = "Scope";
                    slo_class = "SLO class";
                    Value = "Active for";
                  };
                };
              }
              {
                id = "sortBy";
                options = {
                  fields = { };
                  sort = [
                    {
                      field = "Active for";
                      desc = true;
                    }
                  ];
                };
              }
            ];
            options.cellHeight = "sm";
            overrides = [
              {
                matcher = {
                  id = "byName";
                  options = "Severity";
                };
                properties = [
                  viz.pillCell
                  {
                    id = "custom.width";
                    value = 110;
                  }
                  {
                    id = "mappings";
                    value = [
                      {
                        type = "value";
                        options = {
                          critical = {
                            text = "critical";
                            color = "red";
                            index = 0;
                          };
                          warning = {
                            text = "warning";
                            color = "orange";
                            index = 1;
                          };
                        };
                      }
                    ];
                  }
                ];
              }
              {
                matcher = {
                  id = "byName";
                  options = "Active for";
                };
                properties = [
                  {
                    id = "unit";
                    value = viz.units.duration;
                  }
                  {
                    id = "decimals";
                    value = 0;
                  }
                  {
                    id = "custom.width";
                    value = 160;
                  }
                  (viz.colorBackgroundCell { mode = "gradient"; })
                  {
                    id = "thresholds";
                    value = {
                      mode = "absolute";
                      steps = viz.thresholdSteps [
                        { color = "green"; }
                        {
                          color = "orange";
                          value = 3600;
                        }
                        {
                          color = "red";
                          value = 86400;
                        }
                      ];
                    };
                  }
                ];
              }
              {
                matcher = {
                  id = "byName";
                  options = "Endpoint";
                };
                properties = [
                  {
                    id = "links";
                    # Table columns are named after the `organize` rename, and
                    # a table's fields carry no label object, so the row is
                    # addressed through __data rather than __field.labels.
                    value = [
                      (viz.dataLink {
                        title = "Open the log explorer";
                        url = "/d/log-explorer/system-log-explorer?$${__url_time_range}";
                      })
                      (viz.dataLink {
                        title = "Open service health";
                        url = "/d/service-health/service-health?$${__url_time_range}";
                      })
                    ];
                  }
                ];
              }
            ];
          })
        ]
        [ (viz.row "History") ]
        [
          (viz.panel {
            title = "Alert state over time";
            type = "state-timeline";
            w = 24;
            h = 14;
            description = "A gap means the alert was not firing: Prometheus stops emitting the series entirely rather than reporting zero.";
            # Encode the two states as distinct numbers so one series can carry
            # both pending and firing.
            targets = [
              {
                expr = ''
                  label_replace(ALERTS{alertstate="pending",job=~".+-node"} * 1, "host", "$1", "job", "(.+)-node")
                  or label_replace(ALERTS{alertstate="firing",job=~".+-node"} * 2, "host", "$1", "job", "(.+)-node")'';
                legend = "[{{severity}}] {{alertname}} {{host}}";
              }
              {
                expr = ''
                  (ALERTS{alertstate="pending",job!~".+-node"} * 1)
                  or (ALERTS{alertstate="firing",job!~".+-node"} * 2)'';
                legend = "[{{severity}}] {{alertname}} {{endpoint}}{{resolver}}{{job}}";
              }
            ];
            mappings = [
              {
                type = "value";
                options = {
                  "1" = {
                    text = "Pending";
                    color = "orange";
                    index = 0;
                  };
                  "2" = {
                    text = "Firing";
                    color = "red";
                    index = 1;
                  };
                };
              }
            ];
            noValue = "OK";
            options = {
              perPage = 40;
              legend.showLegend = false;
            };
          })
        ]
        [
          (viz.panel {
            title = "Firing over time";
            w = 12;
            h = 8;
            expr = ''sum by (severity) (ALERTS{alertstate="firing"})'';
            legend = "{{severity}}";
            unit = viz.units.none;
            decimals = 0;
            custom = {
              fillOpacity = 50;
              stacking = {
                mode = "normal";
                group = "A";
              };
            };
            overrides = [
              (viz.overrideByName "critical" [
                {
                  id = "color";
                  value = {
                    mode = "fixed";
                    fixedColor = "red";
                  };
                }
              ])
              (viz.overrideByName "warning" [
                {
                  id = "color";
                  value = {
                    mode = "fixed";
                    fixedColor = "orange";
                  };
                }
              ])
            ];
          })
          (viz.panel {
            title = "Noisiest rules";
            type = "bargauge";
            w = 12;
            h = 8;
            description = "How many times each rule entered the pending state over the window -- the flapping detector.";
            targets = [
              {
                expr = "topk(10, sum by (alertname) (changes(ALERTS_FOR_STATE[$__range])))";
                legend = "{{alertname}}";
                instant = true;
              }
            ];
            unit = viz.units.none;
            decimals = 0;
            color.mode = "continuous-YlRd";
          })
        ]
        [ (viz.row "Rule state from Prometheus") ]
        [
          (viz.panel {
            title = "Rules";
            type = "alertlist";
            w = 24;
            h = 14;
            description = "Read live from Prometheus's rules API. Namespaces show as Nix store paths because that is the rule file's location on disk.";
            options = {
              # This is the datasource *name*, not its uid: the panel filters
              # rules by `rule.dataSourceName`.
              datasource = "Prometheus";
              maxItems = 100;
              sortOrder = 3;
            };
          })
        ]
      ];
    };

    "nix-host-combined.json" = viz.dashboard {
      uid = "nix-host-combined";
      title = "Nix / Host Combined";
      tags = [
        "provisioned"
        "fleet"
      ];
      description = "Side-by-side health and resource use for link, iot, and marin. Open a host from the summary for detailed drill-down.";
      rows = [
        [ (viz.row "Fleet summary") ]
        [
          (viz.panel {
            title = "NixOS hosts";
            type = "table";
            w = 24;
            h = 10;
            description = "One row per configured node exporter. DOWN is a failed scrape; NO DATA means the target is missing from Prometheus.";
            links = [
              (viz.dataLink {
                title = "Open host details";
                url = "/d/fleet/fleet?var-node=\${__data.fields[\"Host\"]}&\${__url_time_range}";
              })
            ];
            targets = [
              {
                expr = hostExporterStatus;
                instant = true;
                format = "table";
              }
              {
                expr = "max by (instance) (node_time_seconds{${hostJobSelector}} - node_boot_time_seconds{${hostJobSelector}})";
                instant = true;
                format = "table";
              }
              {
                expr = ''100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{${hostJobSelector},mode="idle"}[$__rate_interval])))'';
                instant = true;
                format = "table";
              }
              {
                expr = "100 * clamp_min(1 - (max by (instance) (node_memory_MemAvailable_bytes{${hostJobSelector}}) / max by (instance) (node_memory_MemTotal_bytes{${hostJobSelector}})), 0)";
                instant = true;
                format = "table";
              }
              {
                expr = ''100 * max by (instance) (1 - (node_filesystem_avail_bytes{${hostJobSelector},mountpoint="/"} / node_filesystem_size_bytes{${hostJobSelector},mountpoint="/"}))'';
                instant = true;
                format = "table";
              }
              {
                expr = ''max by (instance) (node_systemd_units{${hostJobSelector},state="failed"})'';
                instant = true;
                format = "table";
              }
            ];
            transformations = [
              {
                id = "joinByField";
                options = {
                  byField = "instance";
                  mode = "outerTabular";
                };
              }
              {
                id = "organize";
                options = {
                  excludeByName = {
                    Time = true;
                    "Time 1" = true;
                    "Time 2" = true;
                    "Time 3" = true;
                    "Time 4" = true;
                    "Time 5" = true;
                    "Time 6" = true;
                    __name__ = true;
                    "__name__ 1" = true;
                    "__name__ 2" = true;
                    "__name__ 3" = true;
                    "__name__ 4" = true;
                    "__name__ 5" = true;
                    "__name__ 6" = true;
                    "instance 1" = true;
                    "instance 2" = true;
                    "instance 3" = true;
                    "instance 4" = true;
                    "instance 5" = true;
                    "instance 6" = true;
                  };
                  renameByName = {
                    instance = "Host";
                    "Value #A" = "Exporter";
                    "Value #B" = "Uptime";
                    "Value #C" = "CPU";
                    "Value #D" = "Memory";
                    "Value #E" = "Root filesystem";
                    "Value #F" = "Failed units";
                  };
                };
              }
            ];
            options.sortBy = [
              {
                displayName = "Host";
                desc = false;
              }
            ];
            overrides = [
              (viz.overrideByName "Host" [
                {
                  id = "custom.width";
                  value = 140;
                }
              ])
              (viz.overrideByName "Exporter" [
                {
                  id = "mappings";
                  value = hostStatusMappings;
                }
                (viz.colorBackgroundCell { })
                {
                  id = "custom.width";
                  value = 110;
                }
              ])
              (viz.overrideByName "Uptime" [
                {
                  id = "unit";
                  value = viz.units.duration;
                }
                {
                  id = "decimals";
                  value = 0;
                }
                {
                  id = "custom.width";
                  value = 140;
                }
              ])
              (viz.overrideByName "CPU" [
                {
                  id = "unit";
                  value = viz.units.percent;
                }
                {
                  id = "decimals";
                  value = 1;
                }
                {
                  id = "min";
                  value = 0;
                }
                {
                  id = "max";
                  value = 100;
                }
                (viz.gaugeCell { })
                {
                  id = "thresholds";
                  value = {
                    mode = "absolute";
                    steps = viz.thresholdSteps [
                      { color = "green"; }
                      {
                        color = "orange";
                        value = 85;
                      }
                      {
                        color = "red";
                        value = 95;
                      }
                    ];
                  };
                }
              ])
              (viz.overrideByName "Memory" [
                {
                  id = "unit";
                  value = viz.units.percent;
                }
                {
                  id = "decimals";
                  value = 1;
                }
                {
                  id = "min";
                  value = 0;
                }
                {
                  id = "max";
                  value = 100;
                }
                (viz.gaugeCell { })
                {
                  id = "thresholds";
                  value = {
                    mode = "absolute";
                    steps = viz.thresholdSteps [
                      { color = "green"; }
                      {
                        color = "orange";
                        value = 80;
                      }
                      {
                        color = "red";
                        value = 90;
                      }
                    ];
                  };
                }
              ])
              (viz.overrideByName "Root filesystem" [
                {
                  id = "unit";
                  value = viz.units.percent;
                }
                {
                  id = "decimals";
                  value = 1;
                }
                {
                  id = "min";
                  value = 0;
                }
                {
                  id = "max";
                  value = 100;
                }
                (viz.gaugeCell { })
                {
                  id = "thresholds";
                  value = {
                    mode = "absolute";
                    steps = viz.thresholdSteps [
                      { color = "green"; }
                      {
                        color = "orange";
                        value = 80;
                      }
                      {
                        color = "red";
                        value = 90;
                      }
                    ];
                  };
                }
              ])
              (viz.overrideByName "Failed units" [
                {
                  id = "unit";
                  value = viz.units.none;
                }
                {
                  id = "decimals";
                  value = 0;
                }
                (viz.colorBackgroundCell { })
                {
                  id = "thresholds";
                  value = {
                    mode = "absolute";
                    steps = viz.thresholdSteps [
                      { color = "green"; }
                      {
                        color = "red";
                        value = 1;
                      }
                    ];
                  };
                }
              ])
            ];
          })
        ]
        [ (viz.row "Fleet history") ]
        [
          (viz.panel {
            title = "Availability by host";
            type = "status-history";
            w = 24;
            h = 7;
            expr = hostExporterStatus;
            legend = "{{instance}}";
            # Status history only needs enough buckets to show transitions.
            # Let Grafana scale the Prometheus step with the selected range
            # instead of returning every scrape and exceeding its point cap.
            maxDataPoints = 120;
            mappings = hostStatusMappings;
            options.legend.showLegend = false;
          })
        ]
        [
          (viz.panel {
            title = "CPU and memory utilization";
            w = 12;
            h = 8;
            targets = [
              {
                expr = ''100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{${hostJobSelector},mode="idle"}[$__rate_interval])))'';
                legend = "{{instance}} CPU";
              }
              {
                expr = "100 * clamp_min(1 - (max by (instance) (node_memory_MemAvailable_bytes{${hostJobSelector}}) / max by (instance) (node_memory_MemTotal_bytes{${hostJobSelector}})), 0)";
                legend = "{{instance}} memory";
              }
            ];
            unit = viz.units.percent;
            min = 0;
            max = 100;
            decimals = 1;
            custom.fillOpacity = 20;
          })
          (viz.panel {
            title = "Root filesystem and normalized load";
            w = 12;
            h = 8;
            targets = [
              {
                expr = ''100 * max by (instance) (1 - (node_filesystem_avail_bytes{${hostJobSelector},mountpoint="/"} / node_filesystem_size_bytes{${hostJobSelector},mountpoint="/"}))'';
                legend = "{{instance}} root";
              }
              {
                expr = ''100 * max by (instance) (node_load1{${hostJobSelector}}) / count by (instance) (node_cpu_seconds_total{${hostJobSelector},mode="idle"})'';
                legend = "{{instance}} load / cores";
              }
            ];
            unit = viz.units.percent;
            min = 0;
            decimals = 1;
            custom.fillOpacity = 20;
          })
        ]
        [
          (viz.panel {
            title = "Aggregate network throughput";
            w = 12;
            h = 8;
            targets = [
              {
                expr = "sum by (instance) (rate(node_network_receive_bytes_total{${hostJobSelector},${realInterfaces}}[$__rate_interval])) * 8";
                legend = "{{instance}} receive";
              }
              {
                expr = "sum by (instance) (rate(node_network_transmit_bytes_total{${hostJobSelector},${realInterfaces}}[$__rate_interval])) * 8";
                legend = "{{instance}} transmit";
              }
            ];
            unit = viz.units.bitsPerSecond;
            min = 0;
            custom.fillOpacity = 20;
          })
          (viz.panel {
            title = "Aggregate disk throughput";
            w = 12;
            h = 8;
            targets = [
              {
                expr = "sum by (instance) (rate(node_disk_read_bytes_total{${hostJobSelector},${wholeDisks}}[$__rate_interval]))";
                legend = "{{instance}} read";
              }
              {
                expr = "sum by (instance) (rate(node_disk_written_bytes_total{${hostJobSelector},${wholeDisks}}[$__rate_interval]))";
                legend = "{{instance}} write";
              }
            ];
            unit = viz.units.bytesPerSecond;
            min = 0;
            custom.fillOpacity = 20;
          })
        ]
        [
          (viz.panel {
            title = "Failed systemd units by host";
            w = 24;
            h = 7;
            expr = ''max by (instance) (node_systemd_units{${hostJobSelector},state="failed"})'';
            legend = "{{instance}}";
            unit = viz.units.none;
            min = 0;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 1;
              }
            ];
            custom.fillOpacity = 20;
          })
        ]
      ];
    };

    "fleet.json" = viz.dashboard {
      uid = "fleet";
      title = "Fleet / NixOS hosts";
      tags = [
        "provisioned"
        "fleet"
      ];
      description = "Host health for the registered node exporters. Use the host filter to inspect one at a time.";
      templating.list = [
        {
          name = "node";
          label = "Host";
          type = "query";
          datasource = {
            type = "prometheus";
            uid = "prometheus";
          };
          query = "label_values(node_uname_info{${hostJobSelector}}, instance)";
          definition = "label_values(node_uname_info{${hostJobSelector}}, instance)";
          refresh = 1;
          sort = 1;
          multi = false;
          includeAll = false;
          current = {
            selected = true;
            text = "link";
            value = "link";
          };
          options = [ ];
        }
      ];
      rows = [
        [ (viz.row "At a glance") ]
        [
          (viz.panel {
            title = "CPU busy";
            type = "gauge";
            w = 4;
            h = 7;
            # avg() over the idle series normalises across cores without a
            # separate core-count divisor.
            expr = ''100 * (1 - avg(rate(node_cpu_seconds_total{instance="$node",mode="idle"}[$__rate_interval])))'';
            legend = "$node";
            unit = viz.units.percent;
            min = 0;
            max = 100;
            decimals = 1;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 85;
              }
              {
                color = "red";
                value = 95;
              }
            ];
            # Grafana 13 renders this as a ring of discrete segments
            # with an inline sparkline under the value, instead of a
            # single solid arc.
            options = viz.gaugePresets.segmented;
          })
          (viz.panel {
            title = "Memory used";
            type = "gauge";
            w = 4;
            h = 7;
            # MemAvailable, not MemFree: page cache is reclaimable and
            # counting it as "used" makes every Linux box look full.
            expr = ''clamp_min((1 - (node_memory_MemAvailable_bytes{instance="$node"} / node_memory_MemTotal_bytes{instance="$node"})) * 100, 0)'';
            legend = "$node";
            unit = viz.units.percent;
            min = 0;
            max = 100;
            decimals = 1;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 80;
              }
              {
                color = "red";
                value = 90;
              }
            ];
            # Grafana 13 renders this as a ring of discrete segments
            # with an inline sparkline under the value, instead of a
            # single solid arc.
            options = viz.gaugePresets.segmented;
          })
          (viz.panel {
            title = "Root filesystem";
            type = "gauge";
            w = 4;
            h = 7;
            description = "Root filesystem use on the selected NixOS host.";
            expr = ''(1 - (node_filesystem_avail_bytes{instance="$node",mountpoint="/"} / node_filesystem_size_bytes{instance="$node",mountpoint="/"})) * 100'';
            legend = "$node";
            unit = viz.units.percent;
            min = 0;
            max = 100;
            decimals = 1;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 80;
              }
              {
                color = "red";
                value = 90;
              }
            ];
            # Grafana 13 renders this as a ring of discrete segments
            # with an inline sparkline under the value, instead of a
            # single solid arc.
            options = viz.gaugePresets.segmented;
          })
          (viz.panel {
            title = "Uptime";
            type = "stat";
            w = 4;
            h = 7;
            expr = ''node_time_seconds{instance="$node"} - node_boot_time_seconds{instance="$node"}'';
            legend = "$node";
            unit = viz.units.duration;
            thresholds = [ { color = "text"; } ];
            options = {
              graphMode = "none";
              colorMode = "none";
            };
          })
          (viz.panel {
            title = "Failed units";
            type = "stat";
            w = 4;
            h = 7;
            expr = ''node_systemd_units{instance="$node",state="failed"}'';
            legend = "$node";
            unit = viz.units.none;
            decimals = 0;
            noValue = "0";
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 1;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
          (viz.panel {
            title = "Scrape targets down";
            type = "stat";
            w = 4;
            h = 7;
            # `up` has 37 series; a bare stat of it rendered 37 anonymous
            # "1"s. The count of failures is the number worth showing.
            expr = ''count(up{instance="$node",job=~"${nodeJobRegex}"} == 0) or vector(0)'';
            unit = viz.units.none;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 1;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
        ]
        [
          (viz.panel {
            title = "Scrape targets";
            type = "table";
            w = 24;
            h = 8;
            targets = [
              {
                expr = ''up{instance="$node",job=~"${nodeJobRegex}"}'';
                instant = true;
                format = "table";
              }
              {
                expr = ''scrape_duration_seconds{instance="$node",job=~"${nodeJobRegex}"}'';
                instant = true;
                format = "table";
              }
              {
                expr = ''scrape_samples_scraped{instance="$node",job=~"${nodeJobRegex}"}'';
                instant = true;
                format = "table";
              }
            ];
            transformations = [
              {
                id = "joinByField";
                options = {
                  byField = "instance";
                  mode = "outerTabular";
                };
              }
              {
                id = "organize";
                options = {
                  excludeByName = {
                    Time = true;
                    "Time 1" = true;
                    "Time 2" = true;
                    "Time 3" = true;
                    __name__ = true;
                    "__name__ 1" = true;
                    "__name__ 2" = true;
                    "__name__ 3" = true;
                    job = true;
                    "job 1" = true;
                    "job 2" = true;
                    "job 3" = true;
                    endpoint = true;
                    scope = true;
                    slo_class = true;
                  };
                  renameByName = {
                    instance = "Host";
                    "Value #A" = "Up";
                    "Value #B" = "Scrape duration";
                    "Value #C" = "Samples";
                  };
                };
              }
            ];
            options.sortBy = [
              {
                displayName = "Up";
                desc = false;
              }
            ];
            overrides = [
              (viz.overrideByName "Up" [
                {
                  id = "mappings";
                  value = viz.boolMapping { };
                }
                {
                  id = "custom.cellOptions";
                  value = {
                    type = "color-background";
                    mode = "basic";
                  };
                }
                {
                  id = "custom.width";
                  value = 90;
                }
              ])
              (viz.overrideByName "Scrape duration" [
                {
                  id = "unit";
                  value = viz.units.seconds;
                }
                {
                  id = "decimals";
                  value = 3;
                }
              ])
              (viz.overrideByName "Samples" [
                {
                  id = "unit";
                  value = viz.units.short;
                }
              ])
            ];
          })
        ]
        [ (viz.row "CPU, memory and load") ]
        [
          (viz.panel {
            title = "CPU by mode";
            w = 12;
            h = 8;
            targets =
              map
                (mode: {
                  expr = ''sum(rate(node_cpu_seconds_total{instance="$node",mode="${mode}"}[$__rate_interval])) / scalar(count(count(node_cpu_seconds_total{instance="$node"}) by (cpu)))'';
                  legend = mode;
                })
                [
                  "system"
                  "user"
                  "nice"
                  "iowait"
                  "irq"
                  "softirq"
                  "steal"
                  "idle"
                ];
            # Percent stacking normalises the modes to fill the axis, which
            # is why `idle` belongs in the stack rather than being filtered.
            unit = viz.units.percentunit;
            min = 0;
            custom = {
              fillOpacity = 70;
              lineWidth = 0;
              stacking = {
                mode = "percent";
                group = "A";
              };
            };
            options.legend.calcs = [
              "mean"
              "max"
            ];
          })
          (viz.panel {
            title = "Memory";
            w = 12;
            h = 8;
            targets = [
              {
                expr = ''node_memory_MemTotal_bytes{instance="$node"}'';
                legend = "Total";
              }
              {
                expr = ''node_memory_MemTotal_bytes{instance="$node"} - node_memory_MemFree_bytes{instance="$node"} - (node_memory_Cached_bytes{instance="$node"} + node_memory_Buffers_bytes{instance="$node"} + node_memory_SReclaimable_bytes{instance="$node"})'';
                legend = "Used";
              }
              {
                expr = ''node_memory_Cached_bytes{instance="$node"} + node_memory_Buffers_bytes{instance="$node"} + node_memory_SReclaimable_bytes{instance="$node"}'';
                legend = "Cache + buffers";
              }
              {
                expr = ''node_memory_MemFree_bytes{instance="$node"}'';
                legend = "Free";
              }
              {
                expr = ''node_memory_SwapTotal_bytes{instance="$node"} - node_memory_SwapFree_bytes{instance="$node"}'';
                legend = "Swap used";
              }
            ];
            unit = viz.units.bytes;
            min = 0;
            custom = {
              fillOpacity = 40;
              stacking = {
                mode = "normal";
                group = "A";
              };
            };
            overrides = [
              # Total is a ceiling line, not another slice of the stack.
              (viz.overrideByName "Total" [
                {
                  id = "custom.fillOpacity";
                  value = 0;
                }
                {
                  id = "custom.stacking";
                  value = {
                    mode = "normal";
                    group = false;
                  };
                }
                {
                  id = "color";
                  value = {
                    mode = "fixed";
                    fixedColor = "#E0F9D7";
                  };
                }
              ])
            ];
          })
        ]
        [
          (viz.panel {
            title = "Load average";
            w = 12;
            h = 7;
            targets = [
              {
                expr = ''node_load1{instance="$node"}'';
                legend = "1m";
              }
              {
                expr = ''node_load5{instance="$node"}'';
                legend = "5m";
              }
              {
                expr = ''node_load15{instance="$node"}'';
                legend = "15m";
              }
              {
                expr = ''count(count(node_cpu_seconds_total{instance="$node"}) by (cpu))'';
                legend = "Cores";
              }
            ];
            # Load is dimensionless, so it gets `short`, not a percentage.
            unit = viz.units.short;
            min = 0;
            custom.fillOpacity = 20;
            overrides = [
              # The core count is the line load should be compared against.
              (viz.overrideByName "Cores" [
                {
                  id = "custom.fillOpacity";
                  value = 0;
                }
                {
                  id = "custom.lineStyle";
                  value = {
                    fill = "dash";
                    dash = [
                      10
                      10
                    ];
                  };
                }
                {
                  id = "color";
                  value = {
                    mode = "fixed";
                    fixedColor = "dark-red";
                  };
                }
              ])
            ];
          })
          (viz.panel {
            title = "Temperatures";
            w = 12;
            h = 7;
            expr = ''node_hwmon_temp_celsius{instance="$node"}'';
            legend = "{{chip}} / {{sensor}}";
            unit = viz.units.celsius;
            custom.fillOpacity = 0;
            options.legend.placement = "right";
          })
        ]
        [ (viz.row "Storage and network") ]
        [
          (viz.panel {
            title = "Filesystem used";
            type = "bargauge";
            w = 12;
            h = 8;
            targets = [
              {
                expr = ''1 - (node_filesystem_avail_bytes{instance="$node",${realFilesystems}} / node_filesystem_size_bytes{instance="$node",${realFilesystems}})'';
                legend = "{{mountpoint}}";
                instant = true;
              }
            ];
            unit = viz.units.percentunit;
            min = 0;
            max = 1;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 0.8;
              }
              {
                color = "red";
                value = 0.9;
              }
            ];
            options.displayMode = "lcd";
          })
          (viz.panel {
            title = "Filesystem free";
            w = 12;
            h = 8;
            expr = ''node_filesystem_avail_bytes{instance="$node",${realFilesystems}}'';
            legend = "{{mountpoint}}";
            unit = viz.units.bytes;
            min = 0;
            custom.fillOpacity = 20;
          })
        ]
        [
          (viz.panel {
            title = "Disk throughput";
            w = 12;
            h = 7;
            targets = [
              {
                expr = ''rate(node_disk_read_bytes_total{instance="$node",${wholeDisks}}[$__rate_interval])'';
                legend = "{{device}} read";
              }
              {
                expr = ''rate(node_disk_written_bytes_total{instance="$node",${wholeDisks}}[$__rate_interval])'';
                legend = "{{device}} write";
              }
            ];
            unit = viz.units.bytesPerSecond;
            custom = {
              fillOpacity = 30;
              axisLabel = "read (-) / write (+)";
            };
            overrides = [ (viz.negativeY "/read/") ];
          })
          (viz.panel {
            title = "Network throughput";
            w = 12;
            h = 7;
            targets = [
              {
                # The `* 8` is what makes the `bps` bit-rate unit correct.
                expr = ''rate(node_network_receive_bytes_total{instance="$node",${realInterfaces}}[$__rate_interval]) * 8'';
                legend = "{{device}} in";
              }
              {
                expr = ''rate(node_network_transmit_bytes_total{instance="$node",${realInterfaces}}[$__rate_interval]) * 8'';
                legend = "{{device}} out";
              }
            ];
            unit = viz.units.bitsPerSecond;
            custom = {
              fillOpacity = 30;
              axisLabel = "out (-) / in (+)";
            };
            overrides = [ (viz.negativeY "/out/") ];
          })
        ]
        [
          (viz.panel {
            title = "Disk IOPS";
            w = 8;
            h = 7;
            targets = [
              {
                expr = ''rate(node_disk_reads_completed_total{instance="$node",${wholeDisks}}[$__rate_interval])'';
                legend = "{{device}} read";
              }
              {
                expr = ''rate(node_disk_writes_completed_total{instance="$node",${wholeDisks}}[$__rate_interval])'';
                legend = "{{device}} write";
              }
            ];
            unit = viz.units.iops;
            custom.axisLabel = "read (-) / write (+)";
            overrides = [ (viz.negativeY "/read/") ];
          })
          (viz.panel {
            title = "Disk busy";
            w = 8;
            h = 7;
            expr = ''rate(node_disk_io_time_seconds_total{instance="$node",${wholeDisks}}[$__rate_interval])'';
            legend = "{{device}}";
            unit = viz.units.percentunit;
            min = 0;
            custom.fillOpacity = 20;
          })
          (viz.panel {
            title = "Pressure stall";
            w = 8;
            h = 7;
            description = "Share of wall-clock time tasks spent stalled waiting for CPU, memory or IO.";
            targets = [
              {
                expr = ''rate(node_pressure_cpu_waiting_seconds_total{instance="$node"}[$__rate_interval])'';
                legend = "CPU";
              }
              {
                expr = ''rate(node_pressure_memory_waiting_seconds_total{instance="$node"}[$__rate_interval])'';
                legend = "Memory";
              }
              {
                expr = ''rate(node_pressure_io_waiting_seconds_total{instance="$node"}[$__rate_interval])'';
                legend = "IO";
              }
            ];
            unit = viz.units.percentunit;
            min = 0;
            custom.fillOpacity = 20;
          })
        ]
        [ (viz.row "Systemd and services") ]
        [
          (viz.panel {
            title = "Unit states";
            w = 12;
            h = 7;
            targets =
              map
                (state: {
                  expr = ''node_systemd_units{instance="$node",state="${state}"}'';
                  legend = state;
                })
                [
                  "active"
                  "activating"
                  "deactivating"
                  "inactive"
                  "failed"
                ];
            unit = viz.units.short;
            decimals = 0;
            custom = {
              fillOpacity = 60;
              lineWidth = 0;
              stacking = {
                mode = "normal";
                group = "A";
              };
            };
            overrides = [
              (viz.overrideByName "failed" [
                {
                  id = "color";
                  value = {
                    mode = "fixed";
                    fixedColor = "#F2495C";
                  };
                }
              ])
              (viz.overrideByName "active" [
                {
                  id = "color";
                  value = {
                    mode = "fixed";
                    fixedColor = "#73BF69";
                  };
                }
              ])
            ];
          })
          (viz.panel {
            title = "Failed units";
            type = "table";
            w = 12;
            h = 7;
            targets = [
              {
                expr = ''node_systemd_unit_state{${hostJobSelector},state="failed"} == 1'';
                instant = true;
                format = "table";
              }
            ];
            noValue = "No failed units.";
            transformations = [
              {
                id = "organize";
                options = {
                  excludeByName = {
                    Time = true;
                    __name__ = true;
                    instance = true;
                    job = true;
                    state = true;
                    type = true;
                    Value = true;
                  };
                  renameByName.name = "Unit";
                };
              }
            ];
          })
        ]
        [
          (viz.panel {
            title = "OpenClaw gateway";
            type = "state-timeline";
            w = 12;
            h = 6;
            expr = ''openclaw_gateway_active{instance="link"}'';
            legend = "gateway";
            mappings = viz.boolMapping {
              falseText = "INACTIVE";
              trueText = "ACTIVE";
            };
            options.legend.showLegend = false;
          })
          (viz.panel {
            title = "OpenClaw resources";
            w = 12;
            h = 6;
            targets = [
              {
                expr = ''openclaw_gateway_memory_bytes{instance="link"}'';
                legend = "Memory";
              }
              {
                expr = ''rate(openclaw_gateway_cpu_seconds_total{instance="link"}[$__rate_interval])'';
                legend = "CPU";
              }
              {
                expr = ''openclaw_gateway_restarts_total{instance="link"}'';
                legend = "Restarts";
              }
            ];
            unit = viz.units.bytes;
            overrides = [
              (viz.overrideByName "CPU" [
                {
                  id = "unit";
                  value = viz.units.percentunit;
                }
                {
                  id = "custom.axisPlacement";
                  value = "right";
                }
              ])
              (viz.overrideByName "Restarts" [
                {
                  id = "unit";
                  value = viz.units.none;
                }
                {
                  id = "custom.axisPlacement";
                  value = "hidden";
                }
              ])
            ];
          })
        ]
      ];
    };

    "service-health.json" = viz.dashboard {
      uid = "service-health";
      title = "Service health";
      tags = [
        "provisioned"
        "health"
      ];
      description = "Every probed endpoint: is it up, how fast, and when did it last break?";
      rows = [
        [ (viz.row "Endpoints") ]
        [
          (viz.panel {
            title = "Endpoints up";
            type = "stat";
            w = 4;
            h = 6;
            expr = ''sum(min by (endpoint) (probe_success{endpoint!=""})) / count(min by (endpoint) (probe_success{endpoint!=""}))'';
            unit = viz.units.percentunit;
            min = 0;
            max = 1;
            thresholds = [
              { color = "red"; }
              {
                color = "orange";
                value = 0.999;
              }
              {
                color = "green";
                value = 1;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "area";
            };
          })
          (viz.panel {
            title = "Endpoints down";
            type = "stat";
            w = 4;
            h = 6;
            expr = ''count(min by (endpoint) (probe_success{endpoint!=""}) == 0) or vector(0)'';
            unit = viz.units.none;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 1;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
          (viz.panel {
            title = "Slowest probe";
            type = "stat";
            w = 4;
            h = 6;
            expr = ''max(probe_duration_seconds{endpoint!=""})'';
            legend = "slowest";
            unit = viz.units.seconds;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = observability.slo.latencySeconds.internal;
              }
              {
                color = "red";
                value = observability.slo.latencySeconds.public;
              }
            ];
          })
          (viz.panel {
            title = "Nearest certificate expiry";
            type = "stat";
            w = 6;
            h = 6;
            expr = ''min(probe_ssl_earliest_cert_expiry{endpoint!=""} - time())'';
            unit = viz.units.duration;
            thresholds = [
              { color = "red"; }
              {
                color = "orange";
                value = 7 * 24 * 3600;
              }
              {
                color = "green";
                value = 21 * 24 * 3600;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
          (viz.panel {
            title = "Probes configured";
            type = "stat";
            w = 6;
            h = 6;
            targets = [
              {
                expr = ''count(count by (endpoint) (probe_success{endpoint!="",scope="internal"}))'';
                legend = "Internal";
              }
            ]
            ++ lib.optional (!localCutover) {
              expr = ''count(count by (endpoint) (probe_success{endpoint!="",scope="private"}))'';
              legend = "Private (TLS)";
            };
            unit = viz.units.none;
            decimals = 0;
            thresholds = [ { color = "text"; } ];
            options = {
              graphMode = "none";
              colorMode = "none";
              textMode = "value_and_name";
              orientation = "horizontal";
            };
          })
        ]
        [
          (viz.panel {
            title = "Endpoint status";
            type = "table";
            w = 24;
            h = 12;
            description = "One row per logical endpoint. Resolver-level probes are collapsed to their worst result.";
            targets = [
              {
                expr = ''min by (endpoint) (probe_success{endpoint!=""})'';
                instant = true;
                format = "table";
              }
              {
                expr = ''min by (endpoint) (avg_over_time(probe_success{endpoint!=""}[$__range]))'';
                instant = true;
                format = "table";
              }
              {
                expr = ''max by (endpoint) (probe_duration_seconds{endpoint!=""})'';
                instant = true;
                format = "table";
              }
              {
                expr = ''max by (endpoint) (probe_http_status_code{endpoint!=""})'';
                instant = true;
                format = "table";
              }
              {
                expr = ''min by (endpoint) (probe_ssl_earliest_cert_expiry{endpoint!=""}) - time()'';
                instant = true;
                format = "table";
              }
            ];
            transformations = [
              {
                id = "joinByField";
                options = {
                  byField = "endpoint";
                  mode = "outerTabular";
                };
              }
              {
                id = "organize";
                options = {
                  excludeByName = {
                    Time = true;
                    "Time 1" = true;
                    "Time 2" = true;
                    "Time 3" = true;
                    "Time 4" = true;
                    "Time 5" = true;
                    __name__ = true;
                    "__name__ 1" = true;
                    "__name__ 2" = true;
                    "__name__ 3" = true;
                    "__name__ 4" = true;
                    "__name__ 5" = true;
                  };
                  renameByName = {
                    endpoint = "Endpoint";
                    "Value #A" = "Status";
                    "Value #B" = "Uptime (range)";
                    "Value #C" = "Latency";
                    "Value #D" = "HTTP";
                    "Value #E" = "Cert expires";
                  };
                };
              }
            ];
            options = {
              cellHeight = "sm";
              sortBy = [
                {
                  displayName = "Status";
                  desc = false;
                }
              ];
            };
            overrides = [
              (viz.overrideByName "Status" [
                {
                  id = "mappings";
                  value = viz.boolMapping { };
                }
                {
                  id = "custom.cellOptions";
                  value = {
                    type = "color-background";
                    mode = "basic";
                    # Tint the whole row, so a broken endpoint is
                    # unmissable rather than one red square.
                    applyToRow = true;
                  };
                }
                {
                  id = "custom.width";
                  value = 90;
                }
              ])
              (viz.overrideByName "Uptime (range)" [
                {
                  id = "unit";
                  value = viz.units.percentunit;
                }
                {
                  id = "decimals";
                  value = 3;
                }
                {
                  id = "min";
                  value = 0;
                }
                {
                  id = "max";
                  value = 1;
                }
                {
                  id = "custom.cellOptions";
                  value = {
                    type = "gauge";
                    mode = "gradient";
                  };
                }
                {
                  id = "thresholds";
                  value = {
                    mode = "absolute";
                    steps = viz.thresholdSteps [
                      { color = "red"; }
                      {
                        color = "orange";
                        value = 0.9;
                      }
                      {
                        color = "yellow";
                        value = observability.slo.availability;
                      }
                      {
                        color = "green";
                        value = 0.999;
                      }
                    ];
                  };
                }
              ])
              (viz.overrideByName "Latency" [
                {
                  id = "unit";
                  value = viz.units.seconds;
                }
                {
                  id = "decimals";
                  value = 3;
                }
                {
                  id = "custom.cellOptions";
                  value = {
                    type = "color-text";
                  };
                }
                {
                  id = "thresholds";
                  value = {
                    mode = "absolute";
                    steps = viz.thresholdSteps [
                      { color = "green"; }
                      {
                        color = "orange";
                        value = observability.slo.latencySeconds.internal;
                      }
                      {
                        color = "red";
                        value = observability.slo.latencySeconds.public;
                      }
                    ];
                  };
                }
              ])
              (viz.overrideByName "HTTP" [
                {
                  id = "unit";
                  value = viz.units.none;
                }
                {
                  id = "decimals";
                  value = 0;
                }
                {
                  id = "custom.cellOptions";
                  value = {
                    type = "color-text";
                  };
                }
                {
                  id = "thresholds";
                  value = {
                    mode = "absolute";
                    steps = viz.thresholdSteps [
                      { color = "text"; }
                      {
                        color = "green";
                        value = 200;
                      }
                      {
                        color = "yellow";
                        value = 300;
                      }
                      {
                        color = "orange";
                        value = 400;
                      }
                      {
                        color = "red";
                        value = 500;
                      }
                    ];
                  };
                }
              ])
              (viz.overrideByName "Cert expires" [
                {
                  id = "unit";
                  value = viz.units.duration;
                }
                {
                  id = "custom.cellOptions";
                  value = {
                    type = "color-text";
                  };
                }
                {
                  id = "thresholds";
                  value = {
                    mode = "absolute";
                    steps = viz.thresholdSteps [
                      { color = "red"; }
                      {
                        color = "orange";
                        value = 7 * 24 * 3600;
                      }
                      {
                        color = "green";
                        value = 21 * 24 * 3600;
                      }
                    ];
                  };
                }
              ])
            ];
          })
        ]
        [
          (viz.panel {
            title = "Availability timeline";
            type = "state-timeline";
            w = 24;
            h = 14;
            description = "Green bands are healthy runs; the red slivers are the outages.";
            expr = ''min by (endpoint) (probe_success{endpoint!=""})'';
            legend = "{{endpoint}}";
            mappings = viz.boolMapping { };
            options = {
              # 29 probe series would otherwise paginate at Grafana's
              # default of 20 rows.
              perPage = 40;
              legend.showLegend = false;
            };
          })
        ]
        [ (viz.row "Latency") ]
        [
          (viz.panel {
            title = "Probe duration";
            w = 12;
            h = 8;
            expr = ''max by (endpoint) (probe_duration_seconds{endpoint!=""})'';
            legend = "{{endpoint}}";
            unit = viz.units.seconds;
            min = 0;
            custom.fillOpacity = 0;
            options.legend.placement = "right";
            links = [
              (viz.dataLink {
                title = "Logs around this window";
                url = "/d/log-explorer/system-log-explorer?\${__url_time_range}";
              })
              (viz.dataLink {
                title = "Rolling SLO for this endpoint";
                url = "/d/rolling-slo/rolling-slo-error-budget?\${__url_time_range}";
              })
            ];
          })
          (viz.panel {
            title = "Where the time goes";
            w = 12;
            h = 8;
            description = "HTTP phases are additive, so stacking them shows the total and the split at once.";
            expr = ''avg by (phase) (probe_http_duration_seconds{endpoint!=""})'';
            legend = "{{phase}}";
            unit = viz.units.seconds;
            min = 0;
            custom = {
              fillOpacity = 60;
              stacking = {
                mode = "normal";
                group = "A";
              };
            };
          })
        ]
        [
          (viz.panel {
            title = "Latency against availability";
            type = "xychart";
            w = 12;
            h = 10;
            description = "One point per probe over the ${observability.slo.window} window. Bottom-right is healthy; anything drifting left or down is slow, flaky, or both.";
            targets = [
              {
                expr = "max by (endpoint) (endpoint:latency_p95_7d)";
                instant = true;
                format = "table";
              }
              {
                expr = "min by (endpoint) (endpoint:availability_7d)";
                instant = true;
                format = "table";
              }
            ];
            transformations = [
              # The Time columns would collide on the join and confuse the
              # axis matchers, so drop them first.
              {
                id = "organize";
                options = {
                  excludeByName = {
                    Time = true;
                    __name__ = true;
                    job = true;
                    slo_class = true;
                  };
                  indexByName = { };
                  renameByName = { };
                };
              }
              {
                id = "joinByField";
                options = {
                  byField = "endpoint";
                  mode = "outerTabular";
                };
              }
              {
                id = "organize";
                options = {
                  excludeByName = { };
                  indexByName = { };
                  renameByName = {
                    "Value #A" = "p95 latency";
                    "Value #B" = "availability";
                  };
                };
              }
            ];
            unit = viz.units.percentunit;
            color.mode = "continuous-RdYlGr";
            custom = {
              pointSize.fixed = 9;
              axisSoftMin = 0;
            };
            options = {
              mapping = "manual";
              series = [
                {
                  name.fixed = "Probes";
                  frame.matcher = {
                    id = "byIndex";
                    options = 0;
                  };
                  x.matcher = {
                    id = "byName";
                    options = "p95 latency";
                  };
                  y.matcher = {
                    id = "byName";
                    options = "availability";
                  };
                  # Colour and size matchers only bind to numeric fields, so
                  # the availability column doubles as the colour ramp.
                  color.matcher = {
                    id = "byName";
                    options = "availability";
                  };
                }
              ];
            };
            overrides = [
              (viz.overrideByName "p95 latency" [
                {
                  id = "unit";
                  value = viz.units.seconds;
                }
              ])
            ];
          })
          (viz.panel {
            title = "Probe duration distribution";
            type = "histogram";
            w = 12;
            h = 10;
            description = "How probe latency is actually distributed, rather than just its average. Scaled to milliseconds because the bucket size is an integer.";
            # The panel buckets raw values client-side, so it wants the plain
            # series rather than a pre-bucketed histogram.
            expr = ''max by (endpoint) (probe_duration_seconds{endpoint!=""}) * 1000'';
            legend = "{{endpoint}}";
            unit = viz.units.milliseconds;
            custom = {
              fillOpacity = 70;
              gradientMode = "opacity";
            };
            options.bucketCount = 40;
          })
        ]
        [ (viz.row "TLS") ]
        [
          (viz.panel {
            title = "Certificate lifetime remaining";
            type = "bargauge";
            w = 12;
            h = 8;
            targets = [
              {
                expr = ''(min by (endpoint) (probe_ssl_earliest_cert_expiry{endpoint!=""}) - time()) / 86400'';
                legend = "{{endpoint}}";
                instant = true;
              }
            ];
            unit = "d";
            min = 0;
            max = 90;
            decimals = 0;
            thresholds = [
              { color = "red"; }
              {
                color = "orange";
                value = 7;
              }
              {
                color = "yellow";
                value = 21;
              }
              {
                color = "green";
                value = 30;
              }
            ];
            options.displayMode = "lcd";
          })
          (viz.panel {
            title = "Certificate expiry over time";
            w = 12;
            h = 8;
            expr = ''(min by (endpoint) (probe_ssl_earliest_cert_expiry{endpoint!=""}) - time()) / 86400'';
            legend = "{{endpoint}}";
            unit = "d";
            min = 0;
            custom = {
              fillOpacity = 0;
              thresholdsStyle.mode = "dashed";
            };
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 21;
              }
            ];
            color.mode = "palette-classic";
            options.legend.placement = "right";
          })
        ]
      ];
    };

    "rolling-slo.json" = viz.dashboard {
      uid = "rolling-slo";
      title = "Rolling SLO / error budget";
      tags = [
        "provisioned"
        "slo"
      ];
      description = "${observability.slo.window} rolling availability against a ${toString sloTargetPercent}% target.";
      from = "now-7d";
      rows = [
        [ (viz.row "Error budget") ]
        [
          (viz.panel {
            title = "Worst error budget";
            type = "stat";
            w = 6;
            h = 6;
            expr = "min(endpoint:error_budget_remaining_7d)";
            unit = viz.units.percentunit;
            max = 1;
            decimals = 1;
            thresholds = [
              { color = "red"; }
              {
                color = "orange";
                value = 0.25;
              }
              {
                color = "green";
                value = 0.5;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "area";
            };
          })
          (viz.panel {
            title = "Endpoints breaching target";
            type = "stat";
            w = 6;
            h = 6;
            expr = "count(endpoint:error_budget_remaining_7d < 0) or vector(0)";
            unit = viz.units.none;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 1;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
          (viz.panel {
            title = "Fleet availability";
            type = "stat";
            w = 6;
            h = 6;
            expr = "avg(endpoint:availability_7d)";
            unit = viz.units.percentunit;
            min = 0;
            max = 1;
            decimals = 3;
            thresholds = [
              { color = "red"; }
              {
                color = "orange";
                value = 0.9;
              }
              {
                color = "yellow";
                value = observability.slo.availability;
              }
              {
                color = "green";
                value = 0.999;
              }
            ];
            options.colorMode = "background";
          })
          (viz.panel {
            title = "Worst p95 latency";
            type = "stat";
            w = 6;
            h = 6;
            expr = "max(endpoint:latency_p95_7d)";
            unit = viz.units.seconds;
            decimals = 3;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = observability.slo.latencySeconds.internal;
              }
              {
                color = "red";
                value = observability.slo.latencySeconds.public;
              }
            ];
            options.colorMode = "background";
          })
        ]
        [
          (viz.panel {
            title = "Error budget remaining";
            type = "bargauge";
            w = 12;
            h = 12;
            description = "1.0 means the budget is untouched; 0 means it is spent; negative means the ${toString sloTargetPercent}% objective is already breached.";
            targets = [
              {
                expr = "min by (endpoint) (endpoint:error_budget_remaining_7d)";
                legend = "{{endpoint}}";
                instant = true;
              }
            ];
            unit = viz.units.percentunit;
            min = 0;
            max = 1;
            decimals = 1;
            thresholds = [
              { color = "red"; }
              {
                color = "orange";
                value = 0.25;
              }
              {
                color = "green";
                value = 0.5;
              }
            ];
            options.displayMode = "gradient";
          })
          (viz.panel {
            title = "Availability against target";
            type = "bargauge";
            w = 12;
            h = 12;
            targets = [
              {
                expr = "min by (endpoint) (endpoint:availability_7d)";
                legend = "{{endpoint}}";
                instant = true;
              }
            ];
            unit = viz.units.percentunit;
            # Anchoring the bar at the target rather than at zero is what
            # makes a 99.2% and a 99.9% endpoint visibly different.
            min = observability.slo.availability;
            max = 1;
            decimals = 3;
            thresholds = [
              { color = "red"; }
              {
                color = "orange";
                value = observability.slo.availability;
              }
              {
                color = "green";
                value = 0.999;
              }
            ];
            options.displayMode = "lcd";
          })
        ]
        [ (viz.row "Trends") ]
        [
          (viz.panel {
            title = "Error budget burn-down";
            w = 12;
            h = 8;
            expr = "min by (endpoint) (endpoint:error_budget_remaining_7d)";
            legend = "{{endpoint}}";
            unit = viz.units.percentunit;
            max = 1;
            custom = {
              fillOpacity = 0;
              thresholdsStyle.mode = "dashed";
            };
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 0;
              }
            ];
            color.mode = "palette-classic";
            options.legend.placement = "right";
          })
          (viz.panel {
            title = "p95 latency";
            w = 12;
            h = 8;
            expr = "max by (endpoint) (endpoint:latency_p95_7d)";
            legend = "{{endpoint}}";
            unit = viz.units.seconds;
            min = 0;
            custom = {
              fillOpacity = 0;
              thresholdsStyle.mode = "dashed";
            };
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = observability.slo.latencySeconds.internal;
              }
            ];
            color.mode = "palette-classic";
            options.legend.placement = "right";
          })
        ]
      ];
    };

    "log-explorer.json" = viz.dashboard {
      uid = "log-explorer";
      title = "System log explorer";
      tags = [
        "provisioned"
        "logs"
      ];
      description = "Journal from Link. User journals are dropped and secrets redacted before they reach Loki.";
      from = "now-1h";
      templating.list = [
        {
          name = "unit";
          label = "Unit";
          type = "query";
          datasource.uid = "loki";
          query = {
            refId = "LokiVariableQueryEditor-VariableQuery";
            type = 1;
            label = "unit";
            stream = ''{host="link"}'';
          };
          includeAll = true;
          multi = true;
          # Loki labels are time-bounded, so the variable refreshes with
          # the range rather than only on dashboard load.
          allValue = ".+";
          refresh = 2;
          sort = 1;
        }
        {
          # Driven off the label rather than a hand-written list: Alloy's
          # journal priority keyword resolves to `error`/`info`/`notice` here,
          # not the classic syslog `err`/`warning` spellings, so a fixed list
          # offers values that match nothing.
          name = "level";
          label = "Level";
          type = "query";
          datasource.uid = "loki";
          query = {
            refId = "LokiVariableQueryEditor-VariableQuery";
            type = 1;
            label = "level";
            stream = ''{host="link"}'';
          };
          includeAll = true;
          multi = true;
          allValue = ".+";
          refresh = 2;
          sort = 1;
        }
        {
          name = "search";
          label = "Search";
          type = "textbox";
          query = "";
          current = {
            text = "";
            value = "";
          };
        }
      ];
      rows = [
        [
          (viz.panel {
            title = "Log volume by level";
            w = 24;
            h = 6;
            datasource = "loki";
            # `count_over_time` with $__auto makes one bar per plotted
            # bucket, which is what Explore's own volume histogram does.
            expr = ''sum by (level) (count_over_time({host="link", unit=~"$unit", level=~"$level"} |= `$search` [$__auto]))'';
            legend = "{{level}}";
            unit = viz.units.short;
            decimals = 0;
            custom = viz.barsCustom;
            overrides = viz.logLevelOverrides;
            options.legend = {
              calcs = [ "sum" ];
              displayMode = "list";
              placement = "bottom";
              showLegend = true;
            };
          })
        ]
        [
          (viz.panel {
            title = "Journal";
            type = "logs";
            w = 24;
            h = 22;
            datasource = "loki";
            expr = ''{host="link", unit=~"$unit", level=~"$level"} |= `$search`'';
          })
        ]
        [ (viz.row "Noisiest units") ]
        [
          (viz.panel {
            title = "Lines by unit";
            type = "bargauge";
            w = 12;
            h = 9;
            datasource = "loki";
            targets = [
              {
                expr = ''topk(15, sum by (unit) (count_over_time({host="link", unit=~"$unit"} [$__range])))'';
                legend = "{{unit}}";
                instant = true;
              }
            ];
            unit = viz.units.short;
            decimals = 0;
            color.mode = "continuous-BlPu";
          })
          (viz.panel {
            title = "Warnings and errors by unit";
            type = "bargauge";
            w = 12;
            h = 9;
            datasource = "loki";
            targets = [
              {
                expr = ''topk(15, sum by (unit) (count_over_time({host="link", level=~"emerg|alert|crit|critical|err|error|warn|warning"} [$__range])))'';
                legend = "{{unit}}";
                instant = true;
              }
            ];
            unit = viz.units.short;
            decimals = 0;
            color.mode = "continuous-YlRd";
          })
        ]
      ];
    };

    "dns.json" = viz.dashboard {
      uid = "dns";
      title = "DNS / Blocky";
      tags = [
        "provisioned"
        "dns"
      ];
      description = "Private resolver: query volume, what is being blocked, cache behaviour and resolution latency.";
      templating.list = [
        {
          name = "resolver";
          label = "Resolver";
          type = "query";
          datasource.uid = "prometheus";
          query = ''label_values(blocky_query_total{instance=~"${resolverHostRegex}"}, resolver)'';
          definition = ''label_values(blocky_query_total{instance=~"${resolverHostRegex}"}, resolver)'';
          multi = true;
          includeAll = true;
          allValue = ".*";
          current = {
            text = "All";
            value = "$__all";
          };
        }
      ];
      rows = [
        [ (viz.row "Overview") ]
        [
          (viz.panel {
            title = "Blocking";
            type = "stat";
            w = 4;
            h = 5;
            expr = ''min by (resolver) (blocky_blocking_enabled{resolver=~"$resolver"})'';
            legend = "{{resolver}}";
            mappings = viz.boolMapping {
              falseText = "DISABLED";
              trueText = "ENABLED";
              falseColor = "red";
              trueColor = "green";
            };
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
          (viz.panel {
            title = "Query rate";
            type = "stat";
            w = 4;
            h = 5;
            expr = "sum(rate(blocky_query_total[$__rate_interval]))";
            unit = viz.units.reqps;
            decimals = 1;
            thresholds = [ { color = "blue"; } ];
          })
          (viz.panel {
            title = "Blocked";
            type = "stat";
            w = 4;
            h = 5;
            expr = ''sum(increase(blocky_response_total{response_type=~"BLOCKED|REBIND"}[$__range])) / sum(increase(blocky_query_total[$__range]))'';
            unit = viz.units.percentunit;
            min = 0;
            max = 1;
            decimals = 1;
            thresholds = [ { color = "purple"; } ];
            options.graphMode = "none";
          })
          (viz.panel {
            title = "Cache hit rate";
            type = "stat";
            w = 4;
            h = 5;
            expr = "sum(rate(blocky_cache_hits_total[$__rate_interval])) / (sum(rate(blocky_cache_hits_total[$__rate_interval])) + sum(rate(blocky_cache_misses_total[$__rate_interval])))";
            unit = viz.units.percentunit;
            min = 0;
            max = 1;
            decimals = 1;
            thresholds = [
              { color = "red"; }
              {
                color = "orange";
                value = 0.3;
              }
              {
                color = "green";
                value = 0.6;
              }
            ];
          })
          (viz.panel {
            title = "p95 resolution";
            type = "stat";
            w = 4;
            h = 5;
            expr = "histogram_quantile(0.95, sum by (le) (rate(blocky_request_duration_seconds_bucket[$__rate_interval])))";
            unit = viz.units.seconds;
            decimals = 3;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 0.1;
              }
              {
                color = "red";
                value = 0.5;
              }
            ];
          })
          (viz.panel {
            title = "Denylist entries";
            type = "stat";
            w = 4;
            h = 5;
            targets = [
              {
                expr = ''blocky_denylist_cache_entries{instance=~"${resolverHostRegex}",resolver=~"$resolver"}'';
                legend = "{{resolver}} blocked domains";
              }
              {
                expr = ''blocky_cache_entries{instance=~"${resolverHostRegex}",resolver=~"$resolver"}'';
                legend = "{{resolver}} cached answers";
              }
            ];
            unit = viz.units.short;
            decimals = 0;
            thresholds = [ { color = "text"; } ];
            options = {
              graphMode = "none";
              colorMode = "none";
              textMode = "value_and_name";
              orientation = "horizontal";
            };
          })
        ]
        [ (viz.row "Traffic") ]
        [
          (viz.panel {
            title = "Queries by outcome";
            w = 16;
            h = 8;
            expr = "sum by (response_type) (rate(blocky_response_total[$__rate_interval]))";
            legend = "{{response_type}}";
            unit = viz.units.reqps;
            custom = {
              fillOpacity = 50;
              stacking = {
                mode = "normal";
                group = "A";
              };
            };
            overrides = [
              (viz.overrideByRegexp "/(?i)blocked/" [
                {
                  id = "color";
                  value = {
                    mode = "fixed";
                    fixedColor = "red";
                  };
                }
              ])
              (viz.overrideByRegexp "/(?i)cached/" [
                {
                  id = "color";
                  value = {
                    mode = "fixed";
                    fixedColor = "green";
                  };
                }
              ])
            ];
          })
          (viz.panel {
            title = "Record types";
            type = "piechart";
            w = 8;
            h = 8;
            targets = [
              {
                # `ceil(increase(...))` so the slice labels read as whole
                # query counts rather than extrapolated fractions.
                expr = "sum by (type) (ceil(increase(blocky_query_total[$__range])))";
                legend = "{{type}}";
                instant = true;
              }
            ];
            unit = viz.units.short;
            decimals = 0;
          })
        ]
        [
          (viz.panel {
            title = "Top clients";
            type = "bargauge";
            w = 8;
            h = 9;
            targets = [
              {
                expr = "topk(10, sum by (client) (ceil(increase(blocky_query_total[$__range]))))";
                legend = "{{client}}";
                instant = true;
              }
            ];
            unit = viz.units.short;
            decimals = 0;
            color.mode = "continuous-BlPu";
          })
          (viz.panel {
            title = "Query rate by client";
            w = 8;
            h = 9;
            expr = "topk(10, sum by (client) (rate(blocky_query_total[$__rate_interval])))";
            legend = "{{client}}";
            unit = viz.units.reqps;
            custom.fillOpacity = 20;
            options.legend.placement = "right";
          })
          (viz.panel {
            title = "Top block reasons";
            type = "bargauge";
            w = 8;
            h = 9;
            targets = [
              {
                expr = ''topk(10, sum by (reason) (ceil(increase(blocky_response_total{response_type=~"BLOCKED|REBIND"}[$__range]))))'';
                legend = "{{reason}}";
                instant = true;
              }
            ];
            unit = viz.units.short;
            decimals = 0;
            color.mode = "continuous-YlRd";
          })
        ]
        [ (viz.row "Latency and cache") ]
        [
          (viz.panel {
            title = "Resolution latency distribution";
            type = "heatmap";
            w = 12;
            h = 9;
            targets = [
              {
                expr = "sum by (le) (increase(blocky_request_duration_seconds_bucket[$__rate_interval]))";
                legend = "{{le}}";
                format = "heatmap";
              }
            ];
            # The series are already bucketed, so Grafana must not
            # re-bucket them, and the unit belongs on the y-axis.
            options = {
              calculate = false;
              yAxis = {
                unit = viz.units.seconds;
                axisPlacement = "left";
                reverse = false;
              };
            };
          })
          (viz.panel {
            title = "Resolution percentiles";
            w = 12;
            h = 9;
            targets =
              map
                (quantile: {
                  expr = "histogram_quantile(0.${quantile}, sum by (le) (rate(blocky_request_duration_seconds_bucket[$__rate_interval])))";
                  legend = "p${quantile}";
                })
                [
                  "50"
                  "90"
                  "99"
                ];
            unit = viz.units.seconds;
            min = 0;
            custom.fillOpacity = 10;
          })
        ]
        [
          (viz.panel {
            title = "Cache";
            w = 12;
            h = 7;
            targets = [
              {
                expr = ''blocky_cache_entries{instance=~"${resolverHostRegex}",resolver=~"$resolver"}'';
                legend = "{{resolver}} entries";
              }
              {
                expr = ''blocky_prefetch_domain_name_cache_entries{instance=~"${resolverHostRegex}",resolver=~"$resolver"}'';
                legend = "{{resolver}} prefetch candidates";
              }
            ];
            unit = viz.units.short;
            decimals = 0;
          })
          (viz.panel {
            title = "Cache and prefetch rates";
            w = 12;
            h = 7;
            targets = [
              {
                expr = "sum(rate(blocky_cache_hits_total[$__rate_interval]))";
                legend = "Hits";
              }
              {
                expr = "sum(rate(blocky_cache_misses_total[$__rate_interval]))";
                legend = "Misses";
              }
              {
                expr = "sum(rate(blocky_prefetches_total[$__rate_interval]))";
                legend = "Prefetches";
              }
              {
                expr = "sum(rate(blocky_prefetch_hits_total[$__rate_interval]))";
                legend = "Prefetch hits";
              }
            ];
            unit = viz.units.reqps;
          })
        ]
        [
          (viz.panel {
            title = "Blocklist freshness";
            type = "stat";
            w = 8;
            h = 5;
            expr = "time() - max(blocky_last_list_group_refresh_timestamp_seconds)";
            unit = viz.units.duration;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 26 * 3600;
              }
              {
                color = "red";
                value = 72 * 3600;
              }
            ];
            options.graphMode = "none";
          })
          (viz.panel {
            title = "Denylist size by group";
            type = "bargauge";
            w = 8;
            h = 5;
            targets = [
              {
                expr = "sum by (group) (blocky_denylist_cache_entries)";
                legend = "{{group}}";
                instant = true;
              }
            ];
            unit = viz.units.short;
            decimals = 0;
            color.mode = "continuous-BlPu";
          })
          (viz.panel {
            title = "Resolver errors";
            type = "stat";
            w = 8;
            h = 5;
            targets = [
              {
                expr = "sum(increase(blocky_error_total[$__range])) or vector(0)";
                legend = "Errors";
              }
              {
                expr = "sum(increase(blocky_failed_downloads_total[$__range])) or vector(0)";
                legend = "Failed list downloads";
              }
            ];
            unit = viz.units.none;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 1;
              }
            ];
            options = {
              graphMode = "none";
              textMode = "value_and_name";
              orientation = "horizontal";
            };
          })
        ]
      ];
    };

    "telemetry.json" = viz.dashboard {
      uid = "telemetry";
      title = "Telemetry pipeline";
      tags = [
        "provisioned"
        "meta"
      ];
      description = "Prometheus, Loki and Alloy watching themselves. Retention here is ${observability.retention.prometheusTime} or ${observability.retention.prometheusSize}, whichever comes first.";
      rows = [
        [ (viz.row "Prometheus") ]
        [
          (viz.panel {
            title = "Active series";
            type = "stat";
            w = 4;
            h = 5;
            expr = ''prometheus_tsdb_head_series{instance="link"}'';
            legend = "Series";
            unit = viz.units.short;
            thresholds = [ { color = "blue"; } ];
          })
          (viz.panel {
            title = "Block storage";
            type = "stat";
            w = 4;
            h = 5;
            description = "Compared against the 2 GB logical retention limit, which is not a filesystem quota.";
            expr = ''prometheus_tsdb_storage_blocks_bytes{instance="link"}'';
            legend = "Storage";
            unit = viz.units.bytes;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 1800000000;
              }
              {
                color = "red";
                value = 2000000000;
              }
            ];
          })
          (viz.panel {
            title = "Ingestion";
            type = "stat";
            w = 4;
            h = 5;
            expr = ''sum(rate(prometheus_tsdb_head_samples_appended_total{instance="link"}[$__rate_interval]))'';
            legend = "Samples/s";
            unit = viz.units.ops;
            decimals = 0;
            thresholds = [ { color = "blue"; } ];
          })
          (viz.panel {
            title = "Slowest scrape";
            type = "stat";
            w = 4;
            h = 5;
            expr = "max(scrape_duration_seconds)";
            legend = "Duration";
            unit = viz.units.seconds;
            decimals = 3;
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 1;
              }
              {
                color = "red";
                value = 5;
              }
            ];
          })
          (viz.panel {
            title = "Config reload";
            type = "stat";
            w = 4;
            h = 5;
            expr = ''prometheus_config_last_reload_successful{instance="link"}'';
            legend = "Reload";
            mappings = viz.boolMapping {
              falseText = "FAILED";
              trueText = "OK";
            };
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
          (viz.panel {
            title = "Rule failures";
            type = "stat";
            w = 4;
            h = 5;
            expr = ''sum(increase(prometheus_rule_evaluation_failures_total{instance="link"}[$__range])) or vector(0)'';
            legend = "Failures";
            unit = viz.units.none;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 1;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
        ]
        [
          (viz.panel {
            title = "Series cardinality by job";
            type = "bargauge";
            w = 12;
            h = 8;
            targets = [
              {
                expr = ''topk(15, count by (job) ({__name__=~".+"}))'';
                legend = "{{job}}";
                instant = true;
              }
            ];
            unit = viz.units.short;
            decimals = 0;
            color.mode = "continuous-BlPu";
          })
          (viz.panel {
            title = "Scrape duration by job";
            w = 12;
            h = 8;
            expr = "max by (job) (scrape_duration_seconds)";
            legend = "{{job}}";
            unit = viz.units.seconds;
            min = 0;
            custom.fillOpacity = 0;
            options.legend.placement = "right";
          })
        ]
        [
          (viz.panel {
            title = "Head series and chunks";
            w = 8;
            h = 7;
            targets = [
              {
                expr = ''prometheus_tsdb_head_series{instance="link"}'';
                legend = "Series";
              }
              {
                expr = ''prometheus_tsdb_head_chunks{instance="link"}'';
                legend = "Chunks";
              }
            ];
            unit = viz.units.short;
            min = 0;
          })
          (viz.panel {
            title = "Series churn";
            w = 8;
            h = 7;
            targets = [
              {
                expr = ''sum(rate(prometheus_tsdb_head_series_created_total{instance="link"}[$__rate_interval]))'';
                legend = "Created";
              }
              {
                expr = ''sum(rate(prometheus_tsdb_head_series_removed_total{instance="link"}[$__rate_interval]))'';
                legend = "Removed";
              }
            ];
            unit = viz.units.ops;
          })
          (viz.panel {
            title = "Rule evaluation";
            w = 8;
            h = 7;
            expr = ''max by (rule_group) (prometheus_rule_group_last_duration_seconds{instance="link"})'';
            legend = "{{rule_group}}";
            unit = viz.units.seconds;
            min = 0;
          })
        ]
        [ (viz.row "Loki and Alloy") ]
        [
          (viz.panel {
            title = "Lines shipped";
            type = "stat";
            w = 6;
            h = 5;
            description = "Alloy's own count of entries accepted by Loki. A flat zero here means the write path is broken, not that the box is quiet.";
            expr = ''sum(rate(loki_write_sent_entries_total{instance="link"}[$__rate_interval]))'';
            legend = "Lines/s";
            unit = viz.units.ops;
            decimals = 2;
            thresholds = [
              { color = "red"; }
              {
                color = "green";
                value = 0.001;
              }
            ];
            options.colorMode = "background";
          })
          (viz.panel {
            title = "Entries dropped";
            type = "stat";
            w = 6;
            h = 5;
            expr = ''sum(increase(loki_write_dropped_entries_total{instance="link"}[$__range])) or vector(0)'';
            legend = "Dropped";
            unit = viz.units.none;
            decimals = 0;
            thresholds = [
              { color = "green"; }
              {
                color = "red";
                value = 1;
              }
            ];
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
          (viz.panel {
            title = "Ingest volume";
            type = "stat";
            w = 6;
            h = 5;
            expr = ''sum(rate(loki_distributor_bytes_received_total{instance="link"}[$__rate_interval]))'';
            legend = "Bytes/s";
            unit = viz.units.bytesPerSecond;
            thresholds = [ { color = "blue"; } ];
          })
          (viz.panel {
            title = "Active streams";
            type = "stat";
            w = 6;
            h = 5;
            expr = ''sum(loki_ingester_memory_streams{instance="link"}) or vector(0)'';
            legend = "Streams";
            unit = viz.units.short;
            decimals = 0;
            thresholds = [ { color = "blue"; } ];
          })
        ]
        [
          (viz.panel {
            title = "Loki write path";
            w = 12;
            h = 8;
            targets = [
              {
                expr = ''sum(rate(loki_write_sent_entries_total{instance="link"}[$__rate_interval]))'';
                legend = "Sent";
              }
              {
                expr = ''sum by (reason) (rate(loki_write_dropped_entries_total{instance="link"}[$__rate_interval]))'';
                legend = "Dropped ({{reason}})";
              }
              {
                expr = ''sum(rate(loki_source_journal_target_lines_total{instance="link"}[$__rate_interval]))'';
                legend = "Journal lines read";
              }
            ];
            unit = viz.units.ops;
            overrides = [
              (viz.overrideByRegexp "/Dropped/" [
                {
                  id = "color";
                  value = {
                    mode = "fixed";
                    fixedColor = "red";
                  };
                }
              ])
            ];
          })
          (viz.panel {
            title = "Loki request latency";
            w = 12;
            h = 8;
            targets = [
              {
                expr = ''histogram_quantile(0.99, sum by (le, route) (rate(loki_request_duration_seconds_bucket{instance="link"}[$__rate_interval])))'';
                legend = "p99 {{route}}";
              }
            ];
            unit = viz.units.seconds;
            min = 0;
            options.legend.placement = "right";
          })
        ]
        [
          (viz.panel {
            title = "Loki responses by status";
            w = 12;
            h = 7;
            expr = ''sum by (status_code) (rate(loki_request_duration_seconds_count{instance="link"}[$__rate_interval]))'';
            legend = "{{status_code}}";
            unit = viz.units.reqps;
            custom = {
              fillOpacity = 40;
              stacking = {
                mode = "normal";
                group = "A";
              };
            };
            overrides = [
              (viz.overrideByRegexp "/^5/" [
                {
                  id = "color";
                  value = {
                    mode = "fixed";
                    fixedColor = "red";
                  };
                }
              ])
            ];
          })
          (viz.panel {
            title = "Exporter self-health";
            w = 12;
            h = 7;
            targets = [
              {
                expr = ''max by (job) (process_resident_memory_bytes{job=~"prometheus|loki|alloy|blackbox|link-node",instance="link"})'';
                legend = "{{job}} RSS";
              }
            ];
            unit = viz.units.bytes;
            min = 0;
            custom.fillOpacity = 10;
          })
        ]
      ];
    };
  };

  expectedCidrs = [
    "192.168.3.0/24"
    "192.168.5.0/24"
    "192.168.6.0/24"
    "10.100.0.0/24"
  ];
in
{
  flake.grafanaDashboards = dashboards;

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
      nodeScrapeConfigs = map (target: {
        job_name = "${target.hostName}-node";
        static_configs = [
          {
            targets = [ "${target.scrapeAddress}:${toString node.port}" ];
            labels.instance = target.hostName;
          }
        ];
      }) nodeEntries;
      blockyScrapeTargets = map (
        resolver:
        let
          scrapeAddress =
            if resolver.registryName == observability.hubHost then blocky.backendAddress else resolver.lan;
        in
        {
          targets = [ "${scrapeAddress}:${toString blocky.port}" ];
          labels = {
            instance = resolver.hostName;
            resolver = resolver.hostName;
          };
        }
      ) resolverEntries;
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
          https_internal = {
            prober = "http";
            timeout = "8s";
            http = {
              preferred_ip_protocol = "ip4";
              follow_redirects = true;
              fail_if_not_ssl = true;
            };
          };
          dns = {
            prober = "dns";
            timeout = "5s";
            dns = {
              preferred_ip_protocol = "ip4";
              query_name = "grafana.nyc.finnrut.is";
              query_type = "A";
              validate_answer_rrs.fail_if_not_matches_regexp = [
                "^grafana\\.nyc\\.finnrut\\.is.*192\\.168\\.6\\.50$"
              ];
            };
          };
        };
      };

      mkBlackboxScrape =
        {
          name,
          module,
          targets,
          instanceLabel ? "endpoint",
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
              # Keep transport addresses out of Prometheus's public identity
              # label. Dashboards and alerts should name the logical endpoint
              # (or resolver), never its current IP/port/URL.
              source_labels = [ instanceLabel ];
              target_label = "instance";
            }
            {
              target_label = "__address__";
              replacement = "${blackbox.backendAddress}:${toString blackbox.port}";
            }
          ];
        };

      safeInstanceName =
        value:
        builtins.isString value
        && builtins.match "[A-Za-z0-9][A-Za-z0-9.-]*" value != null
        && builtins.match "([0-9]{1,3}\\.){3}[0-9]{1,3}" value == null;
      scrapeHasSafeInstance =
        scrape:
        let
          staticConfigs = scrape.static_configs or [ ];
          explicitInstancesSafe = lib.all (
            static:
            let
              instance = static.labels.instance or null;
            in
            instance != null && safeInstanceName instance
          ) staticConfigs;
          derivedInstanceSafe = lib.any (
            rule:
            (rule.target_label or null) == "instance"
            && lib.elem (rule.source_labels or [ ]) [
              [ "endpoint" ]
              [ "resolver" ]
            ]
          ) (scrape.relabel_configs or [ ]);
        in
        explicitInstancesSafe || derivedInstanceSafe;

      recordingAndAlertRules = yaml.generate "observability-rules.yaml" {
        groups = [
          {
            name = "observability-slo";
            interval = "1m";
            rules = [
              {
                record = "endpoint:availability_7d";
                # A removed probe otherwise keeps producing a rolling value
                # until its last sample ages out of the range vector.
                # Resolver/path copies are implementation details: one endpoint
                # gets one conservative SLO series, using its worst view.
                # The subquery evaluates one effective status per minute. Its
                # `up` fallback counts a failed Blackbox scrape as downtime
                # instead of letting absent probe samples improve the average.
                expr = "min by (endpoint, slo_class) (avg_over_time(${effectiveProbeSuccess}[${observability.slo.window}:1m]) and ${effectiveProbeSuccess})";
              }
              {
                record = "endpoint:error_budget_remaining_7d";
                expr = "1 - ((1 - endpoint:availability_7d) / ${toString (1.0 - observability.slo.availability)})";
              }
              {
                record = "endpoint:latency_p95_7d";
                expr = "max by (endpoint, slo_class) (quantile_over_time(0.95, probe_duration_seconds{${sloProbeSelector}}[${observability.slo.window}]) and probe_duration_seconds{${sloProbeSelector}})";
              }
            ];
          }
          {
            name = "observability-alerts";
            interval = "1m";
            rules = [
              {
                alert = "NixOSHostExporterDown";
                expr = "up{${requiredNodeJobSelector}} == 0";
                for = "5m";
                labels.severity = "critical";
                annotations.summary = "Node exporter on {{ $labels.instance }} is unreachable";
              }
              {
                alert = "PrometheusScrapeTargetDown";
                expr = ''up{job!~"blackbox-.*|${nodeJobRegex}|scraparr|tautulli-exporter"} == 0'';
                for = "10m";
                labels.severity = "warning";
                annotations.summary = "Prometheus cannot scrape {{ $labels.job }}";
              }
              {
                alert = "DnsProbeFailed";
                expr = ''min by (resolver) ((probe_success{job="blackbox-dns"} and on (job, instance) (up{job="blackbox-dns"} == 1)) or up{job="blackbox-dns"}) == 0'';
                for = "5m";
                labels.severity = "warning";
                annotations.summary = "DNS validation probe failed through {{ $labels.resolver }}";
              }
              {
                alert = "AllDnsProbesFailed";
                # Inventory cardinality must not be part of the failure
                # condition: this remains correct when resolvers are added or
                # removed.
                expr = ''max(min by (resolver) ((probe_success{job="blackbox-dns"} and on (job, instance) (up{job="blackbox-dns"} == 1)) or up{job="blackbox-dns"})) == 0'';
                for = "1m";
                labels.severity = "critical";
                annotations.summary = "Every NYC internal DNS probe is failing";
              }
              {
                alert = "DnsBlockingStopped";
                expr = "min by (resolver) (blocky_blocking_enabled) == 0";
                for = "5m";
                labels.severity = "warning";
                annotations.summary = "Blocky filtering stopped on {{ $labels.resolver }}";
              }
              {
                alert = "DnsUpstreamFailures";
                expr = "sum by (resolver) (rate(blocky_error_total[5m])) > 0";
                for = "5m";
                labels.severity = "warning";
                annotations.summary = "Blocky upstream errors persist on {{ $labels.resolver }}";
              }
              {
                alert = "EndpointDown";
                expr = "${endpointProbeSuccess} == 0";
                for = "5m";
                labels.severity = "critical";
                annotations.summary = "Endpoint {{ $labels.endpoint }} is down";
              }
              {
                alert = "SystemdUnitFailed";
                expr = ''node_systemd_unit_state{${requiredNodeJobSelector},state="failed"} == 1'';
                for = "5m";
                labels.severity = "warning";
                annotations.summary = "Systemd unit {{ $labels.name }} is failed on {{ $labels.instance }}";
              }
              {
                alert = "OpenClawGatewayDown";
                expr = ''openclaw_gateway_active{instance="link"} != 1'';
                for = "5m";
                labels.severity = "warning";
                annotations.summary = "OpenClaw gateway service health is degraded";
              }
              {
                alert = "RootDiskPressure";
                expr = ''node_filesystem_avail_bytes{${requiredNodeJobSelector},mountpoint="/",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{${requiredNodeJobSelector},mountpoint="/",fstype!~"tmpfs|overlay"} < 0.15'';
                for = "10m";
                labels.severity = "warning";
                annotations.summary = "Root filesystem on {{ $labels.instance }} has less than 15% free";
              }
              {
                alert = "TelemetryStorageGrowth";
                expr = ''predict_linear(node_filesystem_avail_bytes{job="link-node",instance="link",mountpoint="/",fstype!~"tmpfs|overlay"}[6h], 7 * 24 * 3600) < 0'';
                for = "30m";
                labels.severity = "warning";
                annotations.summary = "Current filesystem growth projects Link root exhaustion within seven days";
              }
              {
                alert = "PrometheusLogicalRetentionNearLimit";
                expr = ''prometheus_tsdb_storage_blocks_bytes{instance="link"} > 1800000000'';
                for = "30m";
                labels.severity = "warning";
                annotations.summary = "Prometheus blocks exceed 1.8 GB; the 2 GB setting is logical retention, not a filesystem quota";
              }
              {
                alert = "ObservabilityTlsExpiring";
                expr = "min by (endpoint) (probe_ssl_earliest_cert_expiry{${sloProbeSelector}}) - time() < 21 * 24 * 3600";
                for = "1h";
                labels.severity = "warning";
                annotations.summary = "TLS certificate for {{ $labels.endpoint }} expires within 21 days";
              }
              {
                alert = "InternalSloLatencyHigh";
                expr = ''endpoint:latency_p95_7d{slo_class="internal"} > ${toString observability.slo.latencySeconds.internal} and on (endpoint, slo_class) ${sloWindowEligibility}'';
                for = "30m";
                labels.severity = "warning";
                annotations.summary = "Internal endpoint p95 latency exceeds one second";
              }
              {
                alert = "PublicSloLatencyHigh";
                expr = ''endpoint:latency_p95_7d{slo_class="public"} > ${toString observability.slo.latencySeconds.public} and on (endpoint, slo_class) ${sloWindowEligibility}'';
                for = "30m";
                labels.severity = "warning";
                annotations.summary = "Public endpoint p95 latency exceeds two seconds";
              }
              {
                alert = "SloErrorBudgetExhausted";
                # Do not call a partial range a seven-day SLO. Requiring the
                # same live probe at the far edge of the window also prevents
                # newly added targets from exhausting their budget during
                # their first week.
                expr = "endpoint:error_budget_remaining_7d < 0 and on (endpoint, slo_class) ${sloWindowEligibility}";
                for = "15m";
                labels.severity = "critical";
                annotations.summary = "{{ $labels.endpoint }} exhausted its 99% seven-day error budget";
              }
            ];
          }
        ];
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

      openclawMetricsRuntimeInputs = [
        pkgs.coreutils
        pkgs.gawk
        pkgs.systemd
        pkgs.util-linux
      ];

      openclawMetrics = pkgs.writeShellApplication {
        name = "openclaw-service-metrics";
        runtimeInputs = openclawMetricsRuntimeInputs;
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
          # shellcheck disable=SC1091
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

      nginxAcl = lib.concatMapStrings (cidr: "allow ${cidr};\n") effectiveTrustedCidrs + "deny all;";
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

      protectedTcpPorts = [ 53 ] ++ lib.optionals (activationReady && !localCutover) [ 443 ];
      firewallPortList = lib.concatMapStringsSep "," toString protectedTcpPorts;
      firewallLoopbackAccept = "iptables -w -A nixos-observability -i lo -s 127.0.0.0/8 -j nixos-fw-accept";
      firewallClientAccepts = lib.concatMapStringsSep "\n" (
        cidr: "iptables -w -A nixos-observability -s ${cidr} -j nixos-fw-accept"
      ) effectiveTrustedCidrs;

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
          assertion =
            observability.trustedClientCidrs == expectedCidrs
            && (!localCutover || publicationSite.trustedClientCidrs == observability.trustedClientCidrs);
          message = "DNS, firewall, and nginx must share the active registry's exact client CIDRs.";
        }
        {
          assertion = lib.hasInfix ''
            ${firewallLoopbackAccept}
            ${firewallClientAccepts}
            iptables -w -A nixos-observability -j nixos-fw-refuse
          '' config.networking.firewall.extraCommands;
          message = "The observability firewall must accept IPv4 loopback before the exact trusted client CIDRs and refusal.";
        }
        {
          assertion = lib.all (endpoint: endpoint.backendAddress == "127.0.0.1") endpointList;
          message = "All Phase 1 application backends must be IPv4 loopback-only.";
        }
        {
          assertion =
            nodeEntries != [ ]
            && requiredNodeHostNames != [ ]
            && lib.length nodeHostNames == lib.length (lib.unique nodeHostNames);
          message = "The observability node registry must contain unique host identities and at least one required node.";
        }
        {
          assertion =
            resolverEntries != [ ]
            && lib.all (
              resolver: resolver.registryName == observability.hubHost || resolver.lan != null
            ) resolverEntries;
          message = "Every remote internal-DNS-capable host needs a LAN address for Blocky scraping.";
        }
        {
          assertion = lib.all scrapeHasSafeInstance config.services.prometheus.scrapeConfigs;
          message = "Every Prometheus scrape must expose a hostname/FQDN instance label, never a transport address.";
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
            && (
              localCutover
              || config.systemd.services.nginx.unitConfig.ConditionPathExists == requiredRuntimeSecrets
            );
          message = "Grafana and HTTPS must remain gated on both runtime secrets.";
        }
        {
          assertion =
            config.services.prometheus.listenAddress == "127.0.0.1"
            && config.services.loki.configuration.server.http_listen_address == "127.0.0.1"
            && config.services.homepage-dashboard.openFirewall == false;
          message = "Prometheus, Loki, and Homepage must not expose their application ports.";
        }
        {
          assertion =
            lib.elem pkgs.gawk openclawMetricsRuntimeInputs
            &&
              config.systemd.services.openclaw-service-metrics.serviceConfig.ExecStart
              == lib.getExe openclawMetrics;
          message = "The OpenClaw metrics unit must execute the generated script with gawk available at runtime.";
        }
      ];

      networking.firewall = {
        extraCommands = ''
          iptables -w -N nixos-observability 2>/dev/null || iptables -w -F nixos-observability
          ${firewallLoopbackAccept}
          ${firewallClientAccepts}
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

      security.acme = lib.mkIf (!localCutover) {
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

      services.nginx = lib.mkIf (!localCutover) {
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
            http_addr = if localCutover then grafanaBindAddress else grafana.backendAddress;
            http_port = grafana.port;
            domain = if localCutover then grafanaCanonical else grafana.dnsName;
            root_url = "https://${if localCutover then grafanaCanonical else grafana.dnsName}/";
            enforce_domain = true;
          };
          analytics = {
            reporting_enabled = false;
            check_for_updates = false;
          };
          # Land on the overview instead of Grafana's stock welcome page.
          dashboards.default_home_dashboard_path = "${dashboardDir}/home.json";
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
                    settings = {
                      bottoken = "$TELEGRAM_BOT_TOKEN";
                      chatid = "$TELEGRAM_CHAT_ID";
                    };
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
        scrapeConfigs =
          nodeScrapeConfigs
          ++ [
            {
              job_name = "prometheus";
              static_configs = [
                {
                  targets = [ "${prometheus.backendAddress}:${toString prometheus.port}" ];
                  labels.instance = "link";
                }
              ];
            }
            {
              job_name = "loki";
              static_configs = [
                {
                  targets = [ "${loki.backendAddress}:${toString loki.port}" ];
                  labels.instance = "link";
                }
              ];
            }
            {
              job_name = "alloy";
              static_configs = [
                {
                  targets = [ "${alloy.backendAddress}:${toString alloy.port}" ];
                  labels.instance = "link";
                }
              ];
            }
            {
              job_name = "blackbox";
              static_configs = [
                {
                  targets = [ "${blackbox.backendAddress}:${toString blackbox.port}" ];
                  labels.instance = "link";
                }
              ];
            }
            {
              job_name = "blocky";
              static_configs = blockyScrapeTargets;
            }
            (mkBlackboxScrape {
              name = "dns";
              module = "dns";
              instanceLabel = "resolver";
              targets = map (resolver: {
                targets = [ "${hostRegistry.${resolver}.homeAddress}:53" ];
                labels = { inherit resolver; };
              }) publicationSite.internalDnsHosts;
            })
            (mkBlackboxScrape {
              name = "internal";
              module = internalProbeModule;
              targets = internalProbes;
            })
          ]
          ++ lib.optional (!localCutover) (mkBlackboxScrape {
            name = "private";
            module = "https_internal";
            targets = privateProbes;
          });
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
            # Loki advertises itself to its own components by auto-detecting
            # the host's primary interface, so it registered as
            # 192.168.6.6:9095 while `grpc_listen_address` above binds
            # loopback only. The distributor then dialled an address nothing
            # was listening on: every push failed with a 500 and the whole
            # journal was silently discarded. `common.instance_addr` covers
            # the query frontend as well as the ring -- pinning the ring alone
            # fixes writes but leaves reads broken.
            instance_addr = loki.backendAddress;
            ring = {
              kvstore.store = "inmemory";
              instance_addr = loki.backendAddress;
            };
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
          (if localCutover then homepageCanonical else homepage.dnsName)
          "${if localCutover then homepageCanonical else homepage.dnsName}:443"
          "localhost:${toString homepage.port}"
          "127.0.0.1:${toString homepage.port}"
        ];
        settings = {
          title = "Link observability";
          headerStyle = "clean";
          statusStyle = "dot";
          hideVersion = true;
          # "stone" is Tailwind's warmest neutral, so the handful of surfaces
          # homepage-theme.css does not reach still land in the blog's family
          # rather than reverting to a cold slate.
          color = "stone";
        };
        # Restyled to match blog.finnrut.is; see the file header for how.
        customCSS = builtins.readFile ./homepage-theme.css;
        services =
          if localCutover then
            homepageServiceGroups
          else
            [
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
      systemd.services.homepage-dashboard.environment.HOSTNAME =
        if localCutover then homepageBindAddress else homepage.backendAddress;

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
      systemd.services."acme-grafana.home.finnrut.is".unitConfig.ConditionPathExists = lib.mkIf (
        !localCutover
      ) requiredRuntimeSecrets;
      systemd.services.alloy.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
      systemd.services.grafana.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
      systemd.services.homepage-dashboard.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
      systemd.services.loki.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
      systemd.services.nginx.unitConfig.ConditionPathExists = lib.mkIf (
        !localCutover
      ) requiredRuntimeSecrets;
      systemd.services.openclaw-service-metrics.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
      systemd.services.prometheus.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
      systemd.services.prometheus-blackbox-exporter.unitConfig.ConditionPathExists =
        requiredRuntimeSecrets;
      systemd.services.prometheus-node-exporter.unitConfig.ConditionPathExists = requiredRuntimeSecrets;
    };
}

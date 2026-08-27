{
  config,
  inputs,
  lib,
  ...
}:
let
  inventory = config.flake.servicePublicationInventory;
  serviceApplications = config.servicePublication.applications;
  blackboxPort = config.observability.endpoints.blackbox.port;
  routeKeys = [
    "plex/root"
    "radarr/root"
    "sonarr/root"
    "seerr/root"
    "bazarr/root"
    "sabnzbd/root"
    "nzbhydra2/root"
    "tautulli/root"
  ];
  expectedApplications = [
    "plex"
    "radarr"
    "sonarr"
    "seerr"
    "bazarr"
    "sabnzbd"
    "nzbhydra2"
    "tautulli"
  ];
  viz = import ../../lib/grafana.nix { inherit lib; };
  mediaTags = [
    "media"
    "provisioned"
  ];
  # The blackbox `endpoint` label is the application's canonical hostname, so
  # deriving the selector from the inventory is both exact and self-maintaining.
  # The old hand-written `.*(plex|radarr|...).*` regex silently missed Seerr,
  # whose canonical is `requests.finnrut.is` and contains none of those words.
  mediaEndpointRegex = lib.concatStringsSep "|" (
    map (application: inventory.applications.${application}.canonical) expectedApplications
  );

  selectedRoutes = lib.genAttrs routeKeys (key: inventory.routes.${key});
  routeFor = application: selectedRoutes."${application}/root";
  directUrl =
    application:
    let
      route = routeFor application;
    in
    "${route.backend.scheme}://${route.backendAddress}:${toString route.backend.port}";
  browserUrl = application: "https://${inventory.applications.${application}.canonical}";

  mediaSecretSource = "${inputs.secrets}/grafana/media.age";
  mediaSecretAvailable = builtins.pathExists mediaSecretSource;
  mediaEnvironment = "/run/agenix/media-observability";
  exporterPorts = {
    scraparr = 7100;
    tautulli = 8000;
  };

  # Scraparr labels every series with `alias`, and its Radarr connector
  # reports the alias capitalised ("Radarr") while the others are lower
  # case. The old `$service` variable offered lower-case values only, so
  # `alias=~"$service"` matched nothing for Radarr and the whole
  # media-services dashboard was blank. Drive the variable off the label
  # itself instead of a hand-written list.
  connectorVariable = {
    name = "service";
    label = "Connector";
    type = "query";
    datasource.uid = "prometheus";
    query = {
      qryType = 1;
      query = "label_values(scraparr_services_up, alias)";
      refId = "PrometheusVariableQueryEditor-VariableQuery";
    };
    includeAll = true;
    multi = true;
    allValue = ".+";
    refresh = 2;
    sort = 1;
  };

  # A live topology of the media pipeline. Canvas geometry is static -- the
  # element and connection lists are config, not data -- but every colour and
  # label is bound to a Prometheus field, so the boxes light up with the real
  # state of each service. Element names are what `targetName` refers to, and
  # each `field` binding matches its target's legendFormat, so those must stay
  # in step.
  topologyNodes = [
    {
      key = "seerr";
      label = "Seerr";
      expr = ''min(scraparr_services_up{scraparr_services="seerr"})'';
      left = 15;
      top = 64;
      to = [
        "radarr"
        "sonarr"
      ];
    }
    {
      key = "radarr";
      label = "Radarr";
      expr = ''min(scraparr_services_up{scraparr_services="radarr"})'';
      left = 170;
      top = 22;
      to = [ "nzbhydra2" ];
    }
    {
      key = "sonarr";
      label = "Sonarr";
      expr = ''min(scraparr_services_up{scraparr_services="sonarr"})'';
      left = 170;
      top = 106;
      to = [ "nzbhydra2" ];
    }
    {
      key = "nzbhydra2";
      label = "NZBHydra2";
      # Scraparr has no NZBHydra connector, so use the endpoint probe that is
      # already generated from the service-publication health contract.
      expr = ''min(probe_success{job=~"blackbox-internal|blackbox-private",endpoint="${inventory.applications.nzbhydra2.canonical}"})'';
      left = 325;
      top = 64;
      to = [ "sabnzbd" ];
    }
    {
      key = "sabnzbd";
      label = "SABnzbd";
      expr = ''min(scraparr_services_up{scraparr_services="sabnzbd"})'';
      left = 480;
      top = 64;
      to = [ "alexandria" ];
    }
    {
      key = "bazarr";
      label = "Bazarr";
      expr = ''min(scraparr_services_up{scraparr_services="bazarr"})'';
      left = 480;
      top = 148;
      to = [ "alexandria" ];
    }
    {
      key = "alexandria";
      label = "Alexandria";
      expr = ''min(probe_success{job="blackbox-internal",endpoint=~"(plex|radarr|sonarr)\\..*"})'';
      left = 635;
      top = 64;
      to = [ "plex" ];
    }
    {
      key = "plex";
      label = "Plex";
      expr = ''min(probe_success{job="blackbox-internal",endpoint=~"plex\\..*"})'';
      left = 790;
      top = 64;
      to = [ "tautulli" ];
    }
    {
      key = "tautulli";
      label = "Tautulli";
      expr = ''min(probe_success{job="blackbox-internal",endpoint=~"tautulli\\..*"})'';
      left = 945;
      top = 64;
      to = [ ];
    }
  ];

  topologyElement = node: {
    name = node.key;
    type = "metric-value";
    config = {
      align = "center";
      valign = "middle";
      size = 14;
      color.fixed = "#000000";
      # In field mode the value runs through the field's display processor, so
      # the UP/DOWN value mappings supply the text.
      text = {
        mode = "field";
        field = node.key;
        fixed = "";
      };
    };
    background.color = {
      field = node.key;
      fixed = "#D9D9D9";
    };
    border = {
      color.fixed = "text";
      width = 2;
      radius = 4;
    };
    constraint = {
      horizontal = "left";
      vertical = "top";
    };
    placement = {
      inherit (node) left top;
      width = 130;
      height = 44;
      rotation = 0;
    };
    # Connection anchors are normalised offsets from the element centre:
    # x grows rightwards, y grows *upwards*, and 1 is the edge.
    connections = map (target: {
      source = {
        x = 1;
        y = 0;
      };
      target = {
        x = -1;
        y = 0;
      };
      targetName = target;
      path = "straight";
      color.field = node.key;
      size = {
        fixed = 2;
        min = 1;
        max = 6;
      };
      direction = {
        mode = "fixed";
        fixed = "forward";
      };
      lineStyle = {
        style = "solid";
        animate = true;
      };
      vertices = [ ];
    }) node.to;
  };

  topologyLabel = node: {
    name = "${node.key}-label";
    type = "text";
    config = {
      align = "center";
      valign = "middle";
      size = 12;
      color.fixed = "text";
      text = {
        mode = "fixed";
        fixed = node.label;
      };
    };
    constraint = {
      horizontal = "left";
      vertical = "top";
    };
    placement = {
      inherit (node) left;
      top = node.top - 24;
      width = 130;
      height = 22;
      rotation = 0;
    };
    connections = [ ];
  };

  mediaDashboards = {
    "media-overview.json" = viz.dashboard {
      uid = "media-overview";
      title = "Media Overview";
      tags = mediaTags;
      description = "Library size, request pipeline, download queues and Plex playback.";
      rows = [
        [ (viz.row "Pipeline") ]
        [
          (viz.panel {
            title = "Media pipeline";
            type = "canvas";
            w = 24;
            h = 8;
            description = "Requests flow left to right: Seerr asks, the *arrs search through NZBHydra2, SABnzbd fetches, Alexandria stores, Plex serves, and Tautulli watches. Every box is coloured by live state.";
            targets = map (node: {
              inherit (node) expr;
              legend = node.key;
              instant = true;
            }) topologyNodes;
            # Canvas resolves a `field` binding through the field's display
            # processor, so these mappings drive both the text and the colour.
            mappings = viz.boolMapping {
              falseText = "DOWN";
              trueText = "UP";
              nullText = "NO DATA";
              nullColor = "purple";
            };
            options.root = {
              name = "root";
              type = "frame";
              elements = map topologyElement topologyNodes ++ map topologyLabel topologyNodes;
            };
          })
        ]
        [ (viz.row "Right now") ]
        [
          (viz.panel {
            title = "Plex streams";
            type = "stat";
            w = 4;
            h = 5;
            expr = "media:plex_streams";
            unit = viz.units.none;
            noValue = "0";
            decimals = 0;
            thresholds = [
              { color = "blue"; }
            ];
            options.graphMode = "area";
          })
          (viz.panel {
            title = "Transcoding";
            type = "stat";
            w = 4;
            h = 5;
            expr = "media:plex_transcodes";
            unit = viz.units.none;
            noValue = "0";
            decimals = 0;
            description = "Transcodes are the expensive streams; direct play costs Alexandria almost nothing.";
            thresholds = [
              { color = "green"; }
              {
                color = "orange";
                value = 2;
              }
              {
                color = "red";
                value = 4;
              }
            ];
          })
          (viz.panel {
            title = "Plex bandwidth";
            type = "stat";
            w = 4;
            h = 5;
            # Tautulli reports kbps, so the series is scaled to bits per
            # second and rendered with a bit-rate unit rather than a bare
            # five-digit number.
            expr = "media:plex_bandwidth_kbps * 1000";
            unit = viz.units.bitsPerSecond;
            noValue = "0";
            thresholds = [ { color = "blue"; } ];
            options.graphMode = "area";
          })
          (viz.panel {
            title = "Download rate";
            type = "stat";
            w = 4;
            h = 5;
            expr = "media:sab_queue_rate_bytes";
            unit = viz.units.bytesPerSecond;
            noValue = "0";
            thresholds = [ { color = "purple"; } ];
            options.graphMode = "area";
          })
          (viz.panel {
            title = "Queued for download";
            type = "stat";
            w = 4;
            h = 5;
            expr = "media:arr_queue_items";
            unit = viz.units.none;
            noValue = "0";
            decimals = 0;
            thresholds = [ { color = "text"; } ];
            options.graphMode = "none";
          })
          (viz.panel {
            title = "Queue remaining";
            type = "stat";
            w = 4;
            h = 5;
            expr = "media:sab_queue_remaining_bytes";
            unit = viz.units.bytes;
            noValue = "0";
            thresholds = [ { color = "text"; } ];
            options.graphMode = "none";
          })
        ]
        [ (viz.row "Library") ]
        [
          (viz.panel {
            title = "Library size";
            type = "stat";
            w = 8;
            h = 5;
            targets = [
              {
                expr = "sum(radarr_movies_total)";
                legend = "Movies";
              }
              {
                expr = "sum(sonarr_series_total)";
                legend = "Series";
              }
              {
                expr = "sum(sonarr_episodes_total)";
                legend = "Episodes";
              }
            ];
            unit = viz.units.short;
            decimals = 0;
            noValue = "0";
            thresholds = [ { color = "green"; } ];
            options = {
              graphMode = "none";
              textMode = "value_and_name";
              orientation = "horizontal";
            };
          })
          (viz.panel {
            title = "On disk";
            type = "bargauge";
            w = 8;
            h = 5;
            targets = [
              {
                expr = "sum(radarr_disk_size_total)";
                legend = "Movies";
                instant = true;
              }
              {
                expr = "sum(sonarr_disk_size_total)";
                legend = "Series";
                instant = true;
              }
            ];
            # 9450791520133 is unreadable; 9.45 TB is the point of the panel.
            unit = viz.units.bytes;
            color = {
              mode = "continuous-BlPu";
            };
          })
          (viz.panel {
            title = "Missing from library";
            type = "bargauge";
            w = 8;
            h = 5;
            targets = [
              {
                expr = "sum(radarr_missing_movies_total)";
                legend = "Movies";
                instant = true;
              }
              {
                expr = "sum(sonarr_missing_episodes_total)";
                legend = "Episodes";
                instant = true;
              }
              {
                expr = "sum(bazarr_wanted_movies_total)";
                legend = "Movie subtitles";
                instant = true;
              }
              {
                expr = "sum(bazarr_wanted_episodes_total)";
                legend = "Episode subtitles";
                instant = true;
              }
            ];
            unit = viz.units.short;
            decimals = 0;
            noValue = "0";
            color = {
              mode = "continuous-YlRd";
            };
          })
        ]
        [
          (viz.panel {
            title = "Library growth";
            w = 24;
            h = 8;
            targets = [
              {
                expr = "sum(radarr_movies_total)";
                legend = "Movies";
              }
              {
                expr = "sum(sonarr_series_total)";
                legend = "Series";
              }
              {
                expr = "sum(sonarr_episodes_total)";
                legend = "Episodes";
              }
              {
                expr = "media:missing_items";
                legend = "Missing";
              }
            ];
            unit = viz.units.short;
            decimals = 0;
            overrides = [
              (viz.overrideByName "Missing" [
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
        ]
        [ (viz.row "Requests") ]
        [
          (viz.panel {
            title = "Requests by status";
            type = "piechart";
            w = 8;
            h = 7;
            # Seerr's status label is Title-cased ("Pending", "Processing"),
            # which is why the old `status=~"pending|processing"` selector
            # returned nothing at all.
            expr = "media:seerr_requests_by_status";
            legend = "{{status}}";
            unit = viz.units.short;
            decimals = 0;
          })
          (viz.panel {
            title = "Awaiting action";
            type = "stat";
            w = 8;
            h = 7;
            targets = [
              {
                expr = ''sum(media:seerr_requests_by_status{status="Pending"}) or vector(0)'';
                legend = "Pending";
              }
              {
                expr = ''sum(media:seerr_requests_by_status{status="Processing"}) or vector(0)'';
                legend = "Processing";
              }
              {
                expr = ''sum(media:seerr_requests_by_status{status="Failed"}) or vector(0)'';
                legend = "Failed";
              }
              {
                expr = "sum(seerr_issue_total) or vector(0)";
                legend = "Open issues";
              }
            ];
            unit = viz.units.none;
            decimals = 0;
            noValue = "0";
            thresholds = [ { color = "text"; } ];
            options = {
              graphMode = "none";
              textMode = "value_and_name";
              orientation = "horizontal";
            };
            overrides = [
              (viz.overrideByName "Failed" [
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
              (viz.overrideByName "Open issues" [
                {
                  id = "thresholds";
                  value = {
                    mode = "absolute";
                    steps = viz.thresholdSteps [
                      { color = "green"; }
                      {
                        color = "orange";
                        value = 1;
                      }
                    ];
                  };
                }
              ])
            ];
          })
          (viz.panel {
            title = "Request backlog";
            w = 8;
            h = 7;
            expr = "media:seerr_requests_by_status";
            legend = "{{status}}";
            unit = viz.units.short;
            decimals = 0;
            custom = {
              fillOpacity = 40;
              stacking = {
                mode = "normal";
                group = "A";
              };
            };
          })
        ]
        [ (viz.row "Downloads") ]
        [
          (viz.panel {
            title = "SABnzbd throughput";
            w = 12;
            h = 7;
            expr = "media:sab_queue_rate_bytes";
            legend = "Download rate";
            unit = viz.units.bytesPerSecond;
            custom.fillOpacity = 30;
          })
          (viz.panel {
            title = "SABnzbd queue";
            w = 12;
            h = 7;
            targets = [
              {
                expr = "media:sab_queue_size_bytes";
                legend = "Queue size";
              }
              {
                expr = "media:sab_queue_remaining_bytes";
                legend = "Remaining";
              }
            ];
            unit = viz.units.bytes;
          })
        ]
        [
          (viz.panel {
            title = "Arr download queues";
            w = 16;
            h = 7;
            targets = [
              {
                expr = "sum(radarr_queue_count)";
                legend = "Radarr";
              }
              {
                expr = "sum(sonarr_queue_count)";
                legend = "Sonarr";
              }
              {
                expr = "media:radarr_queue_problems";
                legend = "Radarr warnings/errors";
              }
              {
                expr = "media:sonarr_queue_problems";
                legend = "Sonarr warnings/errors";
              }
            ];
            unit = viz.units.short;
            decimals = 0;
            overrides = [
              (viz.overrideByRegexp "/warnings/" [
                {
                  id = "color";
                  value = {
                    mode = "fixed";
                    fixedColor = "red";
                  };
                }
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
              ])
            ];
          })
          (viz.panel {
            title = "Downloader paused";
            type = "stat";
            w = 8;
            h = 7;
            expr = "media:sab_queue_paused";
            mappings = viz.boolMapping {
              falseText = "Downloading";
              trueText = "Paused";
              falseColor = "green";
              trueColor = "orange";
            };
            options = {
              colorMode = "background";
              graphMode = "none";
            };
          })
        ]
        [ (viz.row "Plex") ]
        [
          (viz.panel {
            title = "Streams and transcodes";
            w = 12;
            h = 7;
            targets = [
              {
                expr = "plex_active_streams_total";
                legend = "Total streams";
              }
              {
                expr = "plex_active_streams_direct_play";
                legend = "Direct play";
              }
              {
                expr = "plex_active_streams_direct_stream";
                legend = "Direct stream";
              }
              {
                expr = "plex_active_streams_transcode";
                legend = "Transcode";
              }
            ];
            unit = viz.units.none;
            decimals = 0;
            custom.fillOpacity = 20;
            overrides = [
              (viz.overrideByName "Transcode" [
                {
                  id = "color";
                  value = {
                    mode = "fixed";
                    fixedColor = "orange";
                  };
                }
              ])
              (viz.overrideByName "Total streams" [
                {
                  id = "custom.fillOpacity";
                  value = 0;
                }
                {
                  id = "color";
                  value = {
                    mode = "fixed";
                    fixedColor = "blue";
                  };
                }
              ])
            ];
          })
          (viz.panel {
            title = "Plex bandwidth";
            w = 12;
            h = 7;
            targets = [
              {
                expr = "plex_bandwidth_total_kbps * 1000";
                legend = "Total";
              }
              {
                expr = "plex_bandwidth_lan_kbps * 1000";
                legend = "LAN";
              }
              {
                expr = "plex_bandwidth_wan_kbps * 1000";
                legend = "WAN";
              }
            ];
            unit = viz.units.bitsPerSecond;
            custom.fillOpacity = 20;
          })
        ]
        [
          (viz.panel {
            title = "Transcode sessions by kind";
            w = 24;
            h = 6;
            targets = [
              {
                expr = "plex_transcode_video_sessions";
                legend = "Video";
              }
              {
                expr = "plex_transcode_audio_sessions";
                legend = "Audio";
              }
              {
                expr = "plex_transcode_container_sessions";
                legend = "Container";
              }
            ];
            unit = viz.units.none;
            decimals = 0;
            custom = {
              fillOpacity = 40;
              stacking = {
                mode = "normal";
                group = "A";
              };
            };
          })
        ]
      ];
    };

    "media-health.json" = viz.dashboard {
      uid = "media-health";
      title = "Media Health";
      tags = mediaTags;
      description = "Is every media endpoint reachable, and is telemetry fresh?";
      rows = [
        [ (viz.row "Endpoint reachability") ]
        [
          (viz.panel {
            title = "Media endpoints up";
            type = "stat";
            w = 6;
            h = 5;
            # This used to be a bare `probe_success` stat, which rendered
            # one giant "1" per probed endpoint. A ratio answers the
            # question the panel is actually asking.
            expr = ''
              sum(probe_success{job=~"blackbox-internal|blackbox-private",endpoint=~"${mediaEndpointRegex}"})
              / count(probe_success{job=~"blackbox-internal|blackbox-private",endpoint=~"${mediaEndpointRegex}"})'';
            legend = "Reachable";
            unit = viz.units.percentunit;
            min = 0;
            max = 1;
            decimals = 0;
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
              graphMode = "none";
            };
          })
          (viz.panel {
            title = "Down right now";
            type = "table";
            w = 18;
            h = 5;
            # Naming the broken endpoint beats colouring a number.
            targets = [
              {
                expr = ''probe_success{job=~"blackbox-internal|blackbox-private",endpoint=~"${mediaEndpointRegex}"} == 0'';
                instant = true;
                format = "table";
              }
            ];
            noValue = "Every media endpoint is responding.";
            transformations = [
              {
                id = "organize";
                options = {
                  excludeByName = {
                    Time = true;
                    __name__ = true;
                    job = true;
                    slo_class = true;
                    Value = true;
                  };
                  renameByName = {
                    endpoint = "Endpoint";
                    instance = "Target";
                    scope = "Scope";
                  };
                };
              }
            ];
          })
        ]
        [
          (viz.panel {
            title = "Media endpoint state";
            type = "state-timeline";
            w = 24;
            h = 10;
            expr = ''probe_success{job=~"blackbox-internal|blackbox-private",endpoint=~"${mediaEndpointRegex}"}'';
            legend = "{{endpoint}} ({{scope}})";
            mappings = viz.boolMapping { };
            options.legend.showLegend = false;
          })
        ]
        [ (viz.row "Probe latency") ]
        [
          (viz.panel {
            title = "Probe duration";
            w = 12;
            h = 7;
            expr = ''probe_duration_seconds{job=~"blackbox-internal|blackbox-private",endpoint=~"${mediaEndpointRegex}"}'';
            legend = "{{endpoint}} ({{scope}})";
            unit = viz.units.seconds;
          })
          (viz.panel {
            title = "HTTP phase breakdown";
            w = 12;
            h = 7;
            description = "Where the time goes: DNS resolve, TCP connect, TLS handshake, server processing, transfer.";
            expr = ''sum by (phase) (probe_http_duration_seconds{job=~"blackbox-internal|blackbox-private",endpoint=~"${mediaEndpointRegex}"})'';
            legend = "{{phase}}";
            unit = viz.units.seconds;
            custom = {
              fillOpacity = 40;
              stacking = {
                mode = "normal";
                group = "A";
              };
            };
          })
        ]
        [ (viz.row "Exporters and connectors") ]
        [
          (viz.panel {
            title = "Exporter targets";
            type = "stat";
            w = 6;
            h = 5;
            targets = [
              {
                expr = ''up{job="scraparr"}'';
                legend = "Scraparr";
              }
              {
                expr = ''up{job="tautulli-exporter"}'';
                legend = "Tautulli exporter";
              }
              {
                expr = ''probe_success{job="blackbox-tautulli-ready"}'';
                legend = "Tautulli readiness";
              }
            ];
            mappings = viz.boolMapping { };
            options = {
              colorMode = "background";
              graphMode = "none";
              textMode = "value_and_name";
              orientation = "horizontal";
            };
          })
          (viz.panel {
            title = "Connector state";
            type = "state-timeline";
            w = 18;
            h = 5;
            expr = "media:connector_up";
            legend = "{{scraparr_services}}";
            mappings = viz.boolMapping {
              falseText = "FAILING";
              trueText = "OK";
            };
            options.legend.showLegend = false;
          })
        ]
        [
          (viz.panel {
            title = "Telemetry freshness";
            type = "bargauge";
            w = 12;
            h = 7;
            description = "Seconds since each connector last completed a scrape. Scraparr polls every 60s, so anything past a couple of minutes is stale.";
            targets = [
              {
                expr = "time() - max(radarr_last_scrape)";
                legend = "Radarr";
                instant = true;
              }
              {
                expr = "time() - max(sonarr_last_scrape)";
                legend = "Sonarr";
                instant = true;
              }
              {
                expr = "time() - max(bazarr_last_scrape)";
                legend = "Bazarr";
                instant = true;
              }
              {
                expr = "time() - max(sabnzbd_last_scrape)";
                legend = "SABnzbd";
                instant = true;
              }
              {
                expr = "time() - max(seerr_last_scrape)";
                legend = "Seerr";
                instant = true;
              }
            ];
            unit = viz.units.duration;
            thresholds = [
              { color = "green"; }
              {
                color = "#EAB839";
                value = 120;
              }
              {
                color = "red";
                value = 300;
              }
            ];
            options.displayMode = "lcd";
          })
          (viz.panel {
            title = "Scrape duration";
            w = 12;
            h = 7;
            targets = [
              {
                expr = "radarr_scrape_duration";
                legend = "Radarr";
              }
              {
                expr = "sonarr_scrape_duration";
                legend = "Sonarr";
              }
              {
                expr = "bazarr_scrape_duration";
                legend = "Bazarr";
              }
              {
                expr = "sabnzbd_scrape_duration";
                legend = "SABnzbd";
              }
              {
                expr = "seerr_scrape_duration";
                legend = "Seerr";
              }
            ];
            unit = viz.units.seconds;
          })
        ]
        [
          (viz.panel {
            title = "Exporter containers";
            type = "state-timeline";
            w = 24;
            h = 6;
            expr = ''node_systemd_unit_state{name=~"podman-(scraparr|tautulli-exporter)\\.service",state="active"}'';
            legend = "{{name}}";
            mappings = viz.boolMapping {
              falseText = "INACTIVE";
              trueText = "ACTIVE";
            };
            options.legend.showLegend = false;
          })
        ]
      ];
    };

    "media-services.json" = viz.dashboard {
      uid = "media-services";
      title = "Media Services";
      tags = mediaTags;
      description = "Per-connector drill-down. Pick a connector with the variable at the top.";
      templating.list = [ connectorVariable ];
      rows = [
        [
          (viz.panel {
            title = "Connector up";
            type = "stat";
            w = 6;
            h = 5;
            expr = ''media:connector_up{alias=~"$service"}'';
            legend = "{{scraparr_services}}";
            mappings = viz.boolMapping { };
            options = {
              colorMode = "background";
              graphMode = "none";
              textMode = "value_and_name";
            };
          })
          (viz.panel {
            title = "Last scrape";
            type = "bargauge";
            w = 9;
            h = 5;
            targets = [
              {
                expr = ''time() - max by (alias) ({__name__=~"(radarr|sonarr|bazarr|sabnzbd|seerr)_last_scrape",alias=~"$service"})'';
                legend = "{{alias}}";
                instant = true;
              }
            ];
            unit = viz.units.duration;
            thresholds = [
              { color = "green"; }
              {
                color = "#EAB839";
                value = 120;
              }
              {
                color = "red";
                value = 300;
              }
            ];
            options.displayMode = "lcd";
          })
          (viz.panel {
            title = "Scrape duration";
            type = "bargauge";
            w = 9;
            h = 5;
            targets = [
              {
                expr = ''max by (alias) ({__name__=~"(radarr|sonarr|bazarr|sabnzbd|seerr)_scrape_duration",alias=~"$service"})'';
                legend = "{{alias}}";
                instant = true;
              }
            ];
            unit = viz.units.seconds;
            color.mode = "continuous-BlPu";
          })
        ]
        [
          (viz.panel {
            title = "Queues";
            w = 12;
            h = 7;
            targets = [
              {
                expr = ''{__name__=~"(radarr|sonarr)_queue_count",alias=~"$service"}'';
                legend = "{{alias}} queued";
              }
              {
                expr = ''{__name__=~"(radarr|sonarr)_queue_warning",alias=~"$service"}'';
                legend = "{{alias}} warnings";
              }
              {
                expr = ''{__name__=~"(radarr|sonarr)_queue_error",alias=~"$service"}'';
                legend = "{{alias}} errors";
              }
            ];
            unit = viz.units.short;
            decimals = 0;
            overrides = [
              (viz.overrideByRegexp "/errors/" [
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
            title = "Catalogue";
            w = 12;
            h = 7;
            targets = [
              {
                expr = ''{__name__=~"radarr_(movies|monitored_movies|missing_movies)_total",alias=~"$service"}'';
                legend = "{{__name__}}";
              }
              {
                expr = ''{__name__=~"sonarr_(series|episodes|monitored_series|missing_episodes)_total",alias=~"$service"}'';
                legend = "{{__name__}}";
              }
              {
                expr = ''{__name__=~"bazarr_(series|movies|wanted_episodes|wanted_movies)_total",alias=~"$service"}'';
                legend = "{{__name__}}";
              }
            ];
            unit = viz.units.short;
            decimals = 0;
          })
        ]
        [
          (viz.panel {
            title = "Storage consumed";
            w = 12;
            h = 7;
            expr = ''{__name__=~"(radarr|sonarr)_disk_size_total",alias=~"$service"}'';
            legend = "{{alias}}";
            unit = viz.units.bytes;
            custom.fillOpacity = 20;
          })
          (viz.panel {
            title = "SABnzbd storage";
            w = 12;
            h = 7;
            targets = [
              {
                expr = ''sabnzbd_disk_space_bytes{alias=~"$service"}'';
                legend = "Free";
              }
              {
                expr = ''sabnzbd_disk_space_total_bytes{alias=~"$service"}'';
                legend = "Total";
              }
              {
                expr = ''sabnzbd_history_total_bytes{alias=~"$service"}'';
                legend = "Downloaded (lifetime)";
              }
            ];
            unit = viz.units.bytes;
          })
        ]
      ];
    };
  };

  routeContract =
    assert lib.assertMsg (
      builtins.attrNames selectedRoutes == lib.naturalSort routeKeys
    ) "media observability: every selected route must exist exactly once";
    assert lib.assertMsg
      (lib.all (
        application:
        let
          route = routeFor application;
        in
        route.application == application
        && route.route == "root"
        && route.backend.host == "alexandria"
        && route.proxy.host == "link"
        && lib.hasPrefix "https://" (browserUrl application)
      ) expectedApplications)
      "media observability: selected routes must be Link-reachable Alexandria roots with HTTPS canonicals";
    assert lib.assertMsg (lib.all
      (route: !lib.elem route.backend.port (builtins.attrValues exporterPorts))
      (builtins.attrValues selectedRoutes)
    ) "media observability: exporter ports must not collide with Alexandria routes";
    true;
in
{
  flake.grafanaDashboards = mediaDashboards;

  configurations.nixos.link.module =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      yaml = pkgs.formats.yaml { };
      scraparrSettings = {
        general = {
          address = "0.0.0.0";
          port = exporterPorts.scraparr;
          log_level = "INFO";
        };
        radarr = {
          url = directUrl "radarr";
          api_key = "\${RADARR_API_KEY}";
          interval = 60;
          detailed = false;
        };
        sonarr = {
          url = directUrl "sonarr";
          api_key = "\${SONARR_API_KEY}";
          interval = 60;
          detailed = false;
          episode_quality_stats = false;
        };
        bazarr = {
          url = directUrl "bazarr";
          api_key = "\${BAZARR_API_KEY}";
          interval = 60;
          detailed = false;
        };
        sabnzbd = {
          url = directUrl "sabnzbd";
          api_key = "\${SABNZBD_API_KEY}";
          interval = 60;
          detailed = false;
        };
        seerr = {
          url = directUrl "seerr";
          api_key = "\${SEERR_API_KEY}";
          interval = 60;
          detailed = false;
        };
      };
      scraparrConfig = yaml.generate "scraparr-media.yaml" scraparrSettings;

      homepageWidgets = {
        plex = {
          type = "plex";
          url = directUrl "plex";
          key = "{{HOMEPAGE_VAR_PLEX_TOKEN}}";
          fields = [
            "movies"
            "tv"
            "albums"
          ];
        };
        tautulli = {
          type = "tautulli";
          url = directUrl "tautulli";
          key = "{{HOMEPAGE_VAR_TAUTULLI_KEY}}";
          enableUser = true;
          showEpisodeNumber = true;
        };
        radarr = {
          type = "radarr";
          url = directUrl "radarr";
          key = "{{HOMEPAGE_VAR_RADARR_KEY}}";
          enableQueue = true;
          fields = [
            "wanted"
            "missing"
            "queued"
            "movies"
          ];
        };
        sonarr = {
          type = "sonarr";
          url = directUrl "sonarr";
          key = "{{HOMEPAGE_VAR_SONARR_KEY}}";
          enableQueue = true;
          fields = [
            "wanted"
            "queued"
            "series"
          ];
        };
        seerr = {
          type = "overseerr";
          url = directUrl "seerr";
          key = "{{HOMEPAGE_VAR_SEERR_KEY}}";
          fields = [
            "pending"
            "processing"
            "issues"
          ];
        };
        bazarr = {
          type = "bazarr";
          url = directUrl "bazarr";
          key = "{{HOMEPAGE_VAR_BAZARR_KEY}}";
          fields = [
            "missingEpisodes"
            "missingMovies"
          ];
        };
        sabnzbd = {
          type = "sabnzbd";
          url = directUrl "sabnzbd";
          key = "{{HOMEPAGE_VAR_SABNZBD_KEY}}";
          fields = [
            "rate"
            "queue"
            "timeleft"
          ];
        };
      };
      mediaHomepageOrder = {
        plex = 0;
        tautulli = 1;
        seerr = 2;
        radarr = 3;
        sonarr = 4;
        bazarr = 5;
        calibre = 6;
        snapweb = 7;
      };
      homepageServices =
        let
          listed = lib.filterAttrs (_: app: app.homepage.enable) serviceApplications;
          entries = lib.mapAttrsToList (
            name: application:
            let
              routes = builtins.filter (route: route.application == name) (builtins.attrValues inventory.routes);
              roots = builtins.filter (route: route.route == "root") routes;
              monitorRoute = builtins.head (if roots == [ ] then routes else roots);
            in
            {
              serviceName = name;
              group = application.homepage.group;
              displayName =
                if application.homepage.name != null then application.homepage.name else lib.toSentenceCase name;
              entry = {
                href = "https://${inventory.applications.${name}.canonical}";
                siteMonitor = "${monitorRoute.backend.scheme}://${monitorRoute.backendAddress}:${toString monitorRoute.backend.port}${monitorRoute.health.path}";
              }
              // lib.optionalAttrs (application.homepage.description != null) {
                inherit (application.homepage) description;
              }
              // lib.optionalAttrs (application.homepage.icon != null) {
                inherit (application.homepage) icon;
              }
              // lib.optionalAttrs (builtins.hasAttr name homepageWidgets) {
                widget = homepageWidgets.${name};
              };
            }
          ) listed;
        in
        lib.mapAttrsToList (group: items: {
          ${group} = map (item: { ${item.displayName} = item.entry; }) (
            lib.sortOn (
              item: if group == "Media" then mediaHomepageOrder.${item.serviceName} else item.displayName
            ) items
          );
        }) (builtins.groupBy (item: item.group) entries);

      scraparrAllowedMetrics = lib.concatStringsSep "|" [
        "scraparr_services_up"
        "(radarr|sonarr|bazarr|sabnzbd|seerr)_(last_scrape|scrape_duration)"
        "radarr_(queue_count|queue_error|queue_warning|movies_total|disk_size_total|missing_movies_total|monitored_movies_total)"
        "sonarr_(queue_count|queue_error|queue_warning|series_total|episodes_total|disk_size_total|missing_episodes_total|monitored_series_total)"
        "bazarr_(series_total|movies_total|wanted_episodes_total|wanted_movies_total)"
        "sabnzbd_(queue_speed_bytes|queue_size_bytes|queue_remaining_bytes|queue_slots|queue_paused|disk_space_bytes|disk_space_total_bytes|history_total_bytes|history_day_bytes|history_week_bytes|history_month_bytes)"
        "seerr_(request_total|request_tv|request_movie|request_status|issue_total|issue_status|issue_type|issue_media_type|issue_and_media_type)"
        "process_(cpu_seconds_total|resident_memory_bytes|virtual_memory_bytes|open_fds|max_fds|start_time_seconds)"
        "python_gc_(objects_collected_total|objects_uncollectable_total|collections_total)"
      ];
      scraparrSensitiveMetrics = lib.concatStringsSep "|" [
        "seerr_user_requests"
        "(seerr|overseerr|jellyseerr)_(request_timestamp|request_seasons|issue_title|issue_created|issue_updated|user_requests)"
        # Scraparr's per-library-folder breakdowns are the bare metric names
        # carrying a `path` label (`sonarr_series{path="/main/Anime"}`); the
        # aggregates are the `_total` suffixed ones. Prometheus relabel regexes
        # are fully anchored, so `sonarr_series_.*` used to match — and drop —
        # `sonarr_series_total`, which is why `media:library_items` and the
        # library panels evaluated empty. Drop the exact bare names instead.
        "radarr_movies"
        "radarr_movie_.*"
        "sonarr_series"
        "bazarr_wanted_(episodes|movies)"
        "bazarr_provider.*"
        "sabnzbd_server_.*"
        ".*_(quality|genres?).*"
      ];
      tautulliAllowedMetrics = lib.concatStringsSep "|" [
        "plex_active_streams_(total|direct|direct_play|direct_stream|transcode)"
        "plex_transcode_(video|audio|container)_sessions"
        "plex_bandwidth_(total|lan|wan)_kbps"
        "process_(cpu_seconds_total|resident_memory_bytes|virtual_memory_bytes|open_fds|max_fds|start_time_seconds)"
        "python_gc_(objects_collected_total|objects_uncollectable_total|collections_total)"
      ];
      metricKeep = regex: {
        source_labels = [ "__name__" ];
        inherit regex;
        action = "keep";
      };
      metricDrop = regex: {
        source_labels = [ "__name__" ];
        inherit regex;
        action = "drop";
      };

      mediaRuleSettings = {
        groups = [
          {
            name = "media-recording";
            interval = "30s";
            rules = [
              {
                record = "media:connector_up";
                expr = "max by (alias, scraparr_services) (scraparr_services_up)";
              }
              {
                record = "media:radarr_queue_problems";
                expr = "sum(radarr_queue_warning) + sum(radarr_queue_error)";
              }
              {
                record = "media:sonarr_queue_problems";
                expr = "sum(sonarr_queue_warning) + sum(sonarr_queue_error)";
              }
              {
                record = "media:library_items";
                expr = "sum(radarr_movies_total) + sum(sonarr_series_total)";
              }
              {
                record = "media:missing_items";
                expr = "sum(radarr_missing_movies_total) + sum(sonarr_missing_episodes_total)";
              }
              {
                record = "media:arr_queue_items";
                expr = "sum(radarr_queue_count) + sum(sonarr_queue_count)";
              }
              {
                record = "media:plex_streams";
                expr = "sum(plex_active_streams_total)";
              }
              {
                record = "media:plex_transcodes";
                expr = "sum(plex_active_streams_transcode)";
              }
              {
                record = "media:plex_bandwidth_kbps";
                expr = "sum(plex_bandwidth_total_kbps)";
              }
              {
                record = "media:seerr_requests_by_status";
                expr = "sum by (status) (seerr_request_status)";
              }
              {
                # Scraparr exposes only a total for issues, never a per-status
                # breakdown, so the old `sum by (status) (seerr_issue_status)`
                # rule recorded nothing.
                record = "media:seerr_issues_total";
                expr = "sum(seerr_issue_total)";
              }
              {
                record = "media:sab_queue_rate_bytes";
                expr = "sum(sabnzbd_queue_speed_bytes)";
              }
              {
                record = "media:sab_queue_size_bytes";
                expr = "sum(sabnzbd_queue_size_bytes)";
              }
              {
                record = "media:sab_queue_remaining_bytes";
                expr = "sum(sabnzbd_queue_remaining_bytes)";
              }
              {
                record = "media:sab_queue_paused";
                expr = "max(sabnzbd_queue_paused)";
              }
            ];
          }
          {
            name = "media-alerts";
            interval = "1m";
            rules = [
              {
                alert = "MediaApplicationScrapeFailed";
                expr = "scraparr_services_up == 0";
                for = "5m";
                labels.severity = "warning";
                annotations.summary = "Scraparr cannot scrape {{ $labels.scraparr_services }}";
              }
              {
                alert = "MediaExporterTargetDown";
                expr = ''up{job=~"scraparr|tautulli-exporter"} == 0'';
                for = "5m";
                labels.severity = "warning";
                annotations.summary = "Media exporter {{ $labels.job }} is unreachable";
              }
              {
                alert = "RadarrQueueProblem";
                expr = "media:radarr_queue_problems > 0";
                for = "15m";
                labels.severity = "warning";
                annotations.summary = "Radarr queue contains warning or error items";
              }
              {
                alert = "SonarrQueueProblem";
                expr = "media:sonarr_queue_problems > 0";
                for = "15m";
                labels.severity = "warning";
                annotations.summary = "Sonarr queue contains warning or error items";
              }
              {
                alert = "TautulliExporterCannotReachTautulli";
                expr = ''probe_success{job="blackbox-tautulli-ready"} == 0'';
                for = "5m";
                labels.severity = "warning";
                annotations.summary = "Tautulli exporter readiness probe is failing";
              }
            ];
          }
        ];
      };
      mediaRules = yaml.generate "media-observability-rules.yaml" mediaRuleSettings;

      mediaDashboardDir = pkgs.linkFarm "grafana-media-dashboards" (
        lib.mapAttrsToList (name: value: {
          inherit name;
          path = pkgs.writeText name (builtins.toJSON value);
        }) mediaDashboards
      );
      containerHardening = [
        "--cap-drop=ALL"
        "--security-opt=no-new-privileges"
        "--read-only"
        "--tmpfs=/tmp:rw,noexec,nosuid,size=16m"
      ];
      expectedEnvironmentNames = [
        "HOMEPAGE_VAR_PLEX_TOKEN"
        "HOMEPAGE_VAR_RADARR_KEY"
        "HOMEPAGE_VAR_SONARR_KEY"
        "HOMEPAGE_VAR_SEERR_KEY"
        "HOMEPAGE_VAR_BAZARR_KEY"
        "HOMEPAGE_VAR_SABNZBD_KEY"
        "HOMEPAGE_VAR_TAUTULLI_KEY"
        "RADARR_API_KEY"
        "SONARR_API_KEY"
        "SEERR_API_KEY"
        "BAZARR_API_KEY"
        "SABNZBD_API_KEY"
        "TAUTULLI_API_KEY"
      ];
      homepageEnvironmentNames = builtins.filter (lib.hasPrefix "HOMEPAGE_VAR_") expectedEnvironmentNames;
      scraparrEnvironmentNames = [
        "RADARR_API_KEY"
        "SONARR_API_KEY"
        "SEERR_API_KEY"
        "BAZARR_API_KEY"
        "SABNZBD_API_KEY"
      ];
      generatedContainerStartHasEnvironmentFile =
        service:
        lib.hasInfix "--env-file ${mediaEnvironment}" (
          lib.replaceStrings [ "'" ''"'' ] [ "" "" ] config.systemd.services.${service}.script
        );
      mediaRulesJson = builtins.toJSON mediaRuleSettings;
      # Panels now carry several targets each, so the privacy guard reflects
      # over all of them rather than only each panel's first query.
      dashboardPromql = lib.concatStringsSep "\n" (viz.allExpressions mediaDashboards);
    in
    {
      age.secrets.media-observability = lib.mkIf mediaSecretAvailable {
        file = mediaSecretSource;
        path = mediaEnvironment;
        owner = "root";
        group = "root";
        mode = "0400";
      };

      virtualisation.oci-containers.containers = {
        scraparr = {
          autoStart = true;
          image = "ghcr.io/thecfu/scraparr:3.1.0@sha256:c794a9396564e798f9a68fb9dae617db92414cd5c4d41176929657b64873d8bd";
          environmentFiles = [ mediaEnvironment ];
          ports = [ "127.0.0.1:${toString exporterPorts.scraparr}:7100" ];
          volumes = [ "${scraparrConfig}:/app/src/scraparr/config/config.yaml:ro" ];
          extraOptions = containerHardening;
        };
        tautulli-exporter = {
          autoStart = true;
          image = "docker.io/mm404/tautulli-exporter:0.2.2@sha256:1420c72b0c856df48dee6961be9890d0caf434a8b295ba8a8cbebdd020f357c7";
          environmentFiles = [ mediaEnvironment ];
          ports = [ "127.0.0.1:${toString exporterPorts.tautulli}:8000" ];
          environment = {
            TAUTULLI_URL = directUrl "tautulli";
            METRICS_PORT = "8000";
            SCRAPE_INTERVAL = "30";
            LOG_LEVEL = "INFO";
          };
          extraOptions = containerHardening;
        };
      };

      systemd.services = {
        podman-scraparr = {
          after = [
            "agenix.service"
            "network-online.target"
          ];
          wants = [ "network-online.target" ];
          startLimitIntervalSec = 300;
          startLimitBurst = 5;
          unitConfig = {
            ConditionPathExists = mediaEnvironment;
          };
          serviceConfig = {
            EnvironmentFile = mediaEnvironment;
            Restart = "on-failure";
            RestartSec = "10s";
          };
        };
        podman-tautulli-exporter = {
          after = [
            "agenix.service"
            "network-online.target"
          ];
          wants = [ "network-online.target" ];
          startLimitIntervalSec = 300;
          startLimitBurst = 5;
          unitConfig = {
            ConditionPathExists = mediaEnvironment;
          };
          serviceConfig = {
            EnvironmentFile = mediaEnvironment;
            Restart = "on-failure";
            RestartSec = "10s";
          };
        };
        homepage-dashboard = {
          unitConfig.ConditionPathExists = lib.mkAfter [ mediaEnvironment ];
          serviceConfig.EnvironmentFile = [ mediaEnvironment ];
        };
      };

      services.homepage-dashboard.services = lib.mkForce homepageServices;
      services.prometheus = {
        ruleFiles = lib.mkAfter [ mediaRules ];
        scrapeConfigs = lib.mkAfter [
          {
            job_name = "scraparr";
            scrape_interval = "60s";
            static_configs = [ { targets = [ "127.0.0.1:${toString exporterPorts.scraparr}" ]; } ];
            metric_relabel_configs = [
              (metricDrop scraparrSensitiveMetrics)
              (metricKeep scraparrAllowedMetrics)
            ];
          }
          {
            job_name = "tautulli-exporter";
            scrape_interval = "30s";
            static_configs = [ { targets = [ "127.0.0.1:${toString exporterPorts.tautulli}" ]; } ];
            metric_relabel_configs = [ (metricKeep tautulliAllowedMetrics) ];
          }
          {
            job_name = "blackbox-tautulli-ready";
            metrics_path = "/probe";
            params.module = [ "http_internal" ];
            static_configs = [
              {
                targets = [ "http://127.0.0.1:${toString exporterPorts.tautulli}/ready" ];
                labels = {
                  endpoint = "tautulli-exporter-ready";
                  scope = "internal";
                  slo_class = "internal";
                };
              }
            ];
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
                replacement = "127.0.0.1:${toString blackboxPort}";
              }
            ];
          }
        ];
      };

      services.grafana.provision.dashboards.settings.providers = lib.mkAfter [
        {
          name = "Media observability";
          type = "file";
          disableDeletion = true;
          allowUiUpdates = false;
          updateIntervalSeconds = 60;
          options.path = mediaDashboardDir;
        }
      ];

      assertions = [
        {
          assertion = routeContract;
          message = "media observability route derivation contract regressed";
        }
        {
          assertion = config.virtualisation.oci-containers.backend == "podman";
          message = "media exporters require the root-managed Podman OCI backend";
        }
        {
          assertion =
            lib.all
              (
                container:
                config.virtualisation.oci-containers.containers.${container}.environmentFiles
                == [ mediaEnvironment ]
              )
              [
                "scraparr"
                "tautulli-exporter"
              ]
            && lib.all generatedContainerStartHasEnvironmentFile [
              "podman-scraparr"
              "podman-tautulli-exporter"
            ];
          message = "media exporter containers must receive the agenix environment file";
        }
        {
          assertion = lib.all (
            port: !lib.elem port (builtins.attrValues exporterPorts)
          ) config.networking.firewall.allowedTCPPorts;
          message = "media exporter ports must not be opened in the firewall";
        }
        {
          assertion = config.services.prometheus.listenAddress == "127.0.0.1";
          message = "media observability must preserve loopback-only Prometheus";
        }
        {
          assertion = (config.services.grafana.provision.alerting.policies.settings or null) == null;
          message = "media observability must not route Grafana notifications";
        }
        {
          assertion =
            lib.all (name: lib.hasInfix name (builtins.toJSON homepageWidgets)) homepageEnvironmentNames
            && lib.all (
              name: lib.hasInfix "\${${name}}" (builtins.toJSON scraparrSettings)
            ) scraparrEnvironmentNames
            && !(lib.hasInfix "HOMEPAGE_VAR_" (builtins.toJSON scraparrSettings));
          message = "media observability environment-name contract regressed";
        }
        {
          assertion =
            builtins.attrNames scraparrSettings == [
              "bazarr"
              "general"
              "radarr"
              "sabnzbd"
              "seerr"
              "sonarr"
            ]
            &&
              lib.all
                (
                  connector:
                  scraparrSettings.${connector}.interval == 60 && scraparrSettings.${connector}.detailed == false
                )
                [
                  "radarr"
                  "sonarr"
                  "seerr"
                  "bazarr"
                  "sabnzbd"
                ]
            && scraparrSettings.sonarr.episode_quality_stats == false;
          message = "Scraparr intervals, detail controls, or Sonarr quality control regressed";
        }
        {
          assertion =
            !(lib.any (needle: lib.hasInfix needle dashboardPromql) [
              "user="
              "title="
              "path="
              "request="
              "issue="
              "provider="
              "server="
            ]);
          message = "media dashboard PromQL must not select high-cardinality identity labels";
        }
        {
          # The guard above only works if it actually sees every query. Panels
          # carry up to a dozen targets now, so assert the reflection is wired
          # to all of them rather than silently checking a handful.
          assertion =
            builtins.length (viz.allExpressions mediaDashboards)
            >= builtins.foldl' (total: dashboardValue: total + builtins.length dashboardValue.panels) 0 (
              builtins.attrValues mediaDashboards
            );
          message = "media dashboard privacy reflection must cover every panel target";
        }
        {
          # `sonarr_series_.*` used to sit in the drop list and, because
          # Prometheus relabel regexes are fully anchored, it silently removed
          # the `sonarr_series_total` aggregate the library panels depend on.
          assertion =
            !(lib.hasInfix "sonarr_series_.*" scraparrSensitiveMetrics)
            && !(lib.hasInfix "radarr_movies_.*" scraparrSensitiveMetrics)
            && lib.all (metric: lib.hasInfix metric scraparrAllowedMetrics) [
              "series_total"
              "movies_total"
              "episodes_total"
            ];
          message = "the Scraparr drop list must not swallow the aggregates the dashboards query";
        }
        {
          assertion =
            lib.hasInfix "MediaApplicationScrapeFailed" mediaRulesJson
            && lib.hasInfix "MediaExporterTargetDown" mediaRulesJson
            && lib.hasInfix "RadarrQueueProblem" mediaRulesJson
            && lib.hasInfix "SonarrQueueProblem" mediaRulesJson
            && lib.hasInfix "TautulliExporterCannotReachTautulli" mediaRulesJson
            && lib.hasInfix ''"for":"5m"'' mediaRulesJson
            && lib.hasInfix ''"for":"15m"'' mediaRulesJson
            && !(lib.hasInfix "keep_firing_for" mediaRulesJson)
            && !(lib.hasInfix "sabnzbd_history_failed_jobs" mediaRulesJson)
            # Recording rules must reference metrics Scraparr actually emits.
            && !(lib.hasInfix "seerr_issue_status" mediaRulesJson)
            && !(lib.hasInfix "sonarr_series_total\")" mediaRulesJson);
          message = "media alert names, timing, or deferred SAB alert contract regressed";
        }
        {
          assertion =
            lib.hasInfix "seerr_user_requests" scraparrSensitiveMetrics
            && lib.hasInfix "radarr_movie_.*" scraparrSensitiveMetrics
            && lib.hasInfix "|radarr_movies|" scraparrSensitiveMetrics
            && lib.hasInfix "|sonarr_series|" scraparrSensitiveMetrics
            && lib.hasInfix "sonarr_series" scraparrSensitiveMetrics
            && lib.hasInfix "sabnzbd_server_.*" scraparrSensitiveMetrics
            && !(lib.hasInfix "seerr_user_requests" scraparrAllowedMetrics);
          message = "Scraparr metric privacy allow/drop contract regressed";
        }
      ];
    };

  perSystem =
    { pkgs, ... }:
    {
      checks.media-observability-contract =
        pkgs.runCommand "media-observability-contract"
          {
            nativeBuildInputs = [ pkgs.jq ];
            registry = builtins.toJSON inventory;
          }
          ''
            printf '%s\n' "$registry" > registry.json
            jq -e '
              .metadata.containsSecrets == false and
              .applications.plex.public == false and
              .applications.plex.canonical == "plex.nyc.finnrut.is" and
              .routes["plex/root"].backend.host == "alexandria" and
              .routes["plex/root"].backend.port == 32400 and
              .routes["plex/root"].health.path == "/identity" and
              (.cloudflare.dnsRecords | has("plex") | not) and
              ([.cloudflare.tunnel.applications[].application] | index("plex") | not) and
              (.applications | has("scraparr") | not) and
              (.applications | has("tautulli-exporter") | not) and
              ([.routes[].backend.port] | index(7100) | not) and
              ([.routes[].backend.port] | index(8000) | not)
            ' registry.json >/dev/null
            touch "$out"
          '';
    };
}

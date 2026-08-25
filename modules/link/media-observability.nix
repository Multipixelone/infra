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
    "tautulli/root"
  ];
  expectedApplications = [
    "plex"
    "radarr"
    "sonarr"
    "seerr"
    "bazarr"
    "sabnzbd"
    "tautulli"
  ];
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
  scraparrImage = "ghcr.io/thecfu/scraparr:3.1.0@sha256:c794a9396564e798f9a68fb9dae617db92414cd5c4d41176929657b64873d8bd";
  tautulliExporterImage = "docker.io/mm404/tautulli-exporter:0.2.2@sha256:1420c72b0c856df48dee6961be9890d0caf434a8b295ba8a8cbebdd020f357c7";

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
            lib.sortOn (item: item.displayName) items
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
        "radarr_movie_.*"
        "sonarr_series_.*"
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
                record = "media:seerr_issues_by_status";
                expr = "sum by (status) (seerr_issue_status)";
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

      panel = id: title: expr: type: y: {
        inherit id title type;
        datasource.uid = "prometheus";
        gridPos = {
          x = 0;
          inherit y;
          w = 24;
          h = 7;
        };
        targets = [
          {
            refId = "A";
            inherit expr;
            legendFormat = "{{alias}} {{status}} {{job}}";
          }
        ];
        fieldConfig.defaults = { };
        options = { };
      };
      dashboard = uid: title: panels: templating: {
        inherit
          uid
          title
          panels
          templating
          ;
        tags = [
          "media"
          "provisioned"
        ];
        schemaVersion = 41;
        version = 1;
        editable = false;
        refresh = "30s";
        time = {
          from = "now-6h";
          to = "now";
        };
      };
      mediaDashboards = {
        "media-overview.json" = dashboard "media-overview" "Media Overview" [
          (panel 1 "Media health"
            ''min({__name__=~"probe_success|scraparr_services_up|up",job=~"blackbox-internal|scraparr|tautulli-exporter"})''
            "stat"
            0
          )
          (panel 2 "Arr queues" "radarr_queue_count or sonarr_queue_count" "timeseries" 7)
          (panel 3 "Library and missing totals"
            ''{__name__=~"radarr_movies_total|sonarr_series_total|radarr_missing_movies_total|sonarr_missing_episodes_total"}''
            "timeseries"
            14
          )
          (panel 4 "Seerr pending, processing, and issues"
            ''seerr_request_status{status=~"pending|processing"} or seerr_issue_total''
            "timeseries"
            21
          )
          (panel 5 "Bazarr missing subtitles"
            ''{__name__=~"bazarr_wanted_episodes_total|bazarr_wanted_movies_total"}''
            "timeseries"
            28
          )
          (panel 6 "SAB queue"
            ''{__name__=~"sabnzbd_queue_speed_bytes|sabnzbd_queue_size_bytes|sabnzbd_queue_remaining_bytes"}''
            "timeseries"
            35
          )
          (panel 7 "Plex streams and transcodes" ''{__name__=~"plex_active_streams_.*|plex_transcode_.*"}''
            "timeseries"
            42
          )
          (panel 8 "Plex bandwidth" ''{__name__=~"plex_bandwidth_.*"}'' "timeseries" 49)
        ] { list = [ ]; };
        "media-health.json" = dashboard "media-health" "Media Health" [
          (panel 1 "Media endpoint probes"
            ''probe_success{job=~"blackbox-internal|blackbox-private",endpoint=~".*(plex|radarr|sonarr|seerr|bazarr|sabnzbd|tautulli).*"}''
            "stat"
            0
          )
          (panel 2 "Exporter and connector health"
            ''up{job=~"scraparr|tautulli-exporter"} or scraparr_services_up''
            "stat"
            7
          )
          (panel 3 "Scrape age"
            ''time() - {__name__=~"radarr_last_scrape|sonarr_last_scrape|bazarr_last_scrape|sabnzbd_last_scrape|seerr_last_scrape"}''
            "timeseries"
            14
          )
          (panel 4 "Scrape duration"
            ''{__name__=~"radarr_scrape_duration|sonarr_scrape_duration|bazarr_scrape_duration|sabnzbd_scrape_duration|seerr_scrape_duration"}''
            "timeseries"
            21
          )
          (panel 5 "Tautulli readiness" ''probe_success{job="blackbox-tautulli-ready"}'' "stat" 28)
          (panel 6 "Exporter systemd units"
            ''node_systemd_unit_state{name=~"podman-(scraparr|tautulli-exporter)\\.service",state=~"active|failed"}''
            "stat"
            35
          )
        ] { list = [ ]; };
        "media-services.json" =
          dashboard "media-services" "Media Services"
            [
              (panel 1 "Connector health" ''media:connector_up{scraparr_services=~"$service"}'' "stat" 0)
              (panel 2 "Aggregate service metrics"
                ''{__name__=~"(radarr|sonarr|bazarr|sabnzbd|seerr)_.*",alias=~"$service"}''
                "timeseries"
                7
              )
            ]
            {
              list = [
                {
                  name = "service";
                  type = "custom";
                  query = "radarr,sonarr,bazarr,sabnzbd,seerr";
                  includeAll = true;
                  multi = true;
                }
              ];
            };
      };
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
      dashboardPromql = lib.concatStringsSep "\n" (
        lib.concatMap (
          dashboardValue: map (panelValue: (builtins.head panelValue.targets).expr) dashboardValue.panels
        ) (builtins.attrValues mediaDashboards)
      );
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
          image = scraparrImage;
          environmentFiles = [ mediaEnvironment ];
          ports = [ "127.0.0.1:${toString exporterPorts.scraparr}:7100" ];
          volumes = [ "${scraparrConfig}:/app/src/scraparr/config/config.yaml:ro" ];
          extraOptions = containerHardening;
        };
        tautulli-exporter = {
          autoStart = true;
          image = tautulliExporterImage;
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
          assertion =
            lib.hasInfix "MediaApplicationScrapeFailed" mediaRulesJson
            && lib.hasInfix "MediaExporterTargetDown" mediaRulesJson
            && lib.hasInfix "RadarrQueueProblem" mediaRulesJson
            && lib.hasInfix "SonarrQueueProblem" mediaRulesJson
            && lib.hasInfix "TautulliExporterCannotReachTautulli" mediaRulesJson
            && lib.hasInfix ''"for":"5m"'' mediaRulesJson
            && lib.hasInfix ''"for":"15m"'' mediaRulesJson
            && !(lib.hasInfix "keep_firing_for" mediaRulesJson)
            && !(lib.hasInfix "sabnzbd_history_failed_jobs" mediaRulesJson);
          message = "media alert names, timing, or deferred SAB alert contract regressed";
        }
        {
          assertion =
            lib.hasInfix "seerr_user_requests" scraparrSensitiveMetrics
            && lib.hasInfix "radarr_movie_.*" scraparrSensitiveMetrics
            && lib.hasInfix "sonarr_series_.*" scraparrSensitiveMetrics
            && lib.hasInfix "sabnzbd_server_.*" scraparrSensitiveMetrics
            && !(lib.hasInfix "seerr_user_requests" scraparrAllowedMetrics);
          message = "Scraparr metric privacy allow/drop contract regressed";
        }
        {
          assertion =
            scraparrImage
            == "ghcr.io/thecfu/scraparr:3.1.0@sha256:c794a9396564e798f9a68fb9dae617db92414cd5c4d41176929657b64873d8bd"
            &&
              tautulliExporterImage
              == "docker.io/mm404/tautulli-exporter:0.2.2@sha256:1420c72b0c856df48dee6961be9890d0caf434a8b295ba8a8cbebdd020f357c7";
          message = "media exporter image pins changed without review";
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

{ config, lib, ... }:
let
  hubHost = config.observability.hubHost;
  nonempty = label: ''${label}=~".+"'';
  publishedAlerts = ''alertname=~"EndpointDown|PublishedRouteDown"'';
  alertmanagerSettings = {
    route = {
      receiver = "non-paging";
      group_by = [
        "alertname"
        "endpoint"
        "service"
        "instance"
      ];
      group_wait = "30s";
      group_interval = "5m";
      repeat_interval = "4h";
      routes = [
        {
          matchers = [ ''alertname="SloErrorBudgetExhausted"'' ];
          receiver = "non-paging";
        }
        {
          matchers = [ ''severity="critical"'' ];
          receiver = "telegram";
        }
      ];
    };
    receivers = [
      { name = "non-paging"; }
      {
        name = "telegram";
        telegram_configs = [
          {
            bot_token = "$TELEGRAM_BOT_TOKEN";
            # JSON is YAML, but a quoted substitution would remain a string.
            # Replace this sentinel with an unquoted placeholder below.
            chat_id = "__TELEGRAM_CHAT_ID__";
            send_resolved = true;
            parse_mode = "";
            message = ''
              {{ range .Alerts }}{{ .Status }}: {{ .Labels.alertname }}
              {{ if .Labels.endpoint }}{{ .Labels.endpoint }}{{ else if .Labels.service }}{{ .Labels.service }}{{ else if .Labels.instance }}{{ .Labels.instance }}{{ else }}unknown target{{ end }} — since {{ .StartsAt | date "2006-01-02 15:04 UTC" }}
              {{ .Annotations.summary }}
              {{ if .Annotations.description }}Hint: {{ .Annotations.description }}
              {{ end }}{{ if .Annotations.runbook }}Runbook: {{ .Annotations.runbook }}
              {{ end }}{{ end }}
            '';
          }
        ];
      }
    ];
    inhibit_rules = [
      {
        source_matchers = [
          ''alertname=~"PlexBackendDown|PublishedRouteDown"''
          (nonempty "endpoint")
        ];
        target_matchers = [
          ''alertname="EndpointDown"''
          (nonempty "endpoint")
        ];
        equal = [ "endpoint" ];
      }
      {
        source_matchers = [
          ''alertname="NixOSHostExporterDown"''
          (nonempty "backend_host")
        ];
        target_matchers = [
          ''alertname="EndpointDown"''
          (nonempty "backend_host")
        ];
        equal = [ "backend_host" ];
      }
      {
        source_matchers = [
          ''alertname="AllDnsProbesFailed"''
          (nonempty "site")
        ];
        target_matchers = [
          publishedAlerts
          ''access_path="published"''
          (nonempty "site")
        ];
        equal = [ "site" ];
      }
      {
        source_matchers = [
          ''alertname="BlackboxExporterDown"''
          (nonempty "probe_exporter")
        ];
        target_matchers = [
          publishedAlerts
          (nonempty "probe_exporter")
        ];
        equal = [ "probe_exporter" ];
      }
    ];
  };
  alertmanagerText = lib.replaceStrings [ ''"__TELEGRAM_CHAT_ID__"'' ] [ "$TELEGRAM_CHAT_ID" ] (
    builtins.toJSON alertmanagerSettings
  );
in
{
  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      telegramEnvironment = config.age.secrets."telegram-deadman".path or "/run/agenix/telegram-deadman";
      requiredSecrets = config.systemd.services.prometheus.unitConfig.ConditionPathExists;
    in
    {
      services.prometheus = {
        alertmanagers = [ { static_configs = [ { targets = [ "127.0.0.1:9093" ]; } ]; } ];
        alertmanager = {
          enable = true;
          listenAddress = "127.0.0.1";
          port = 9093;
          openFirewall = false;
          extraFlags = [ "--cluster.listen-address=" ];
          environmentFile = telegramEnvironment;
          configText = alertmanagerText;
          # The unresolved chat-id placeholder is not an integer. The focused
          # check below validates the exact template with dummy credentials.
          checkConfig = false;
        };
      };
      systemd.services.alertmanager = {
        unitConfig.ConditionPathExists = requiredSecrets ++ [ telegramEnvironment ];
        serviceConfig = {
          UMask = "0077";
          ExecStartPre = lib.mkBefore [
            (pkgs.writeShellScript "alertmanager-validate-environment" ''
              if [[ -z "''${TELEGRAM_BOT_TOKEN:-}" || ! "''${TELEGRAM_CHAT_ID:-}" =~ ^-?[1-9][0-9]*$ ]]; then
                echo "Alertmanager requires a bot token and a nonzero numeric Telegram chat ID" >&2
                exit 1
              fi
            '')
          ];
        };
      };
      assertions = [
        {
          assertion =
            config.services.prometheus.alertmanager.listenAddress == "127.0.0.1"
            && !config.services.prometheus.alertmanager.openFirewall
            && lib.elem "--cluster.listen-address=" config.services.prometheus.alertmanager.extraFlags
            && !lib.elem config.services.prometheus.alertmanager.port config.networking.firewall.allowedTCPPorts;
          message = "Alertmanager API must be loopback-only, with clustering and firewall exposure disabled.";
        }
        {
          assertion =
            !(lib.any (point: lib.any (receiver: receiver.type == "telegram") (point.receivers or [ ])) (
              config.services.grafana.provision.alerting.contactPoints.settings.contactPoints or [ ]
            ));
          message = "Prometheus Telegram delivery belongs to Alertmanager; do not provision a duplicate Grafana Telegram receiver.";
        }
      ];
    };

  perSystem =
    { pkgs, system, ... }:
    let
      link = config.flake.nixosConfigurations.link.config;
      rawConfig = pkgs.writeText "alertmanager-template.json" alertmanagerText;
      python = pkgs.python3.withPackages (p: [ p.pyyaml ]);
      fixtures = ./fixtures/plex-alerts.json;
      prometheusConfig =
        if link.services.prometheus.enableReload then
          link.environment.etc."prometheus/prometheus.yaml".source
        else
          builtins.appendContext (builtins.head (builtins.match ".*--config.file=([^ ]+).*" link.systemd.services.prometheus.serviceConfig.ExecStart)) (
            builtins.getContext link.systemd.services.prometheus.serviceConfig.ExecStart
          );
    in
    # These checks consume the real Link configuration and its native
    # derivations; do not introduce x86 build dependencies into ARM checks.
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.alertmanager-config =
        pkgs.runCommand "alertmanager-config-check"
          {
            nativeBuildInputs = [
              pkgs.envsubst
              pkgs.prometheus-alertmanager
              python
            ];
          }
          ''
            export TELEGRAM_BOT_TOKEN=test-only-no-delivery
            export TELEGRAM_CHAT_ID=-1
            envsubst -i ${rawConfig} -o alertmanager.json
            amtool check-config alertmanager.json
            amtool config routes test --config.file=alertmanager.json --verify.receivers=telegram alertname=EndpointDown endpoint=plex.nyc.finnrut.is severity=critical
            amtool config routes test --config.file=alertmanager.json --verify.receivers=non-paging alertname=SloErrorBudgetExhausted severity=critical
            amtool config routes test --config.file=alertmanager.json --verify.receivers=non-paging alertname=EndpointDown severity=warning
            python3 ${./fixtures/check-alerting.py} inhibition alertmanager.json
            python3 ${./fixtures/check-alerting.py} render alertmanager.json
            touch "$out"
          '';
      checks.prometheus-alerting-rules =
        pkgs.runCommand "prometheus-alerting-rules-check"
          {
            nativeBuildInputs = [
              pkgs.prometheus.cli
              python
            ];
          }
          ''
            promtool check rules ${lib.escapeShellArgs link.services.prometheus.ruleFiles}
            python3 ${./fixtures/check-alerting.py} rules ${fixtures} ${lib.escapeShellArg config.flake.servicePublicationInventory.applications.plex.canonical} ${lib.escapeShellArgs link.services.prometheus.ruleFiles}
            promtool test rules suite.json
            touch "$out"
          '';
      checks.prometheus-alerting-config =
        pkgs.runCommand "prometheus-alerting-config-check"
          {
            nativeBuildInputs = [ pkgs.prometheus.cli ];
          }
          ''
            promtool check config ${prometheusConfig}
            touch "$out"
          '';
    };
}

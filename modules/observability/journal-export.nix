{
  config,
  inputs,
  lib,
  ...
}:
let
  journal = config.observability.journal;
  hostRegistry = config.hosts;
  hubHostName = config.observability.hubHost;
  hubAddress =
    if builtins.hasAttr hubHostName hostRegistry then hostRegistry.${hubHostName}.homeAddress else null;
  quote = builtins.toJSON;
  hasEnabledSources =
    sourceServices:
    sourceServices != { } && lib.any (source: source.units != [ ]) (builtins.attrValues sourceServices);
  supportedSources = lib.filterAttrs (
    hostName: _:
    hostName != hubHostName
    && builtins.hasAttr hostName hostRegistry
    && hostRegistry.${hostName}.isNixOS
  ) journal.sources;

  sourceModule =
    hostName: sourceServices:
    let
      client = journal.clients.${hostName} or null;
      enabled = client != null && hasEnabledSources sourceServices;
      allUnits = lib.concatMap (source: source.units) (builtins.attrValues sourceServices);
      unitAlternation = lib.concatStringsSep "|" (map lib.escapeRegex allUnits);
      allowedUnitRegex = "^(${unitAlternation})$";
      allowedMissingUnitRegex = "^(${unitAlternation});$";
      combinedUnitRegex = "^(?:(?:${unitAlternation});[^;]*;[^;]*|[^;]*;(?:${unitAlternation});[^;]*|[^;]*;[^;]*;(?:${unitAlternation}))$";
      clientPasswordSecret = if client == null then "journal-ingress-password" else client.passwordSecret;
      clientUsername = if client == null then "journal" else client.username;
      passwordAgeFile = "${inputs.secrets}/observability/${clientPasswordSecret}.age";
      passwordRuntimePath = "/run/agenix/${clientPasswordSecret}";
      credentialName = "journal-push-password";
      credentialPath = "/run/credentials/alloy.service/${credentialName}";
      passwordAvailable = builtins.pathExists passwordAgeFile;
      serviceRule =
        serviceName: source:
        let
          serviceUnits = lib.concatStringsSep "|" (map lib.escapeRegex source.units);
        in
        ''
          rule {
            source_labels = ["unit"]
            regex         = ${quote "^(${serviceUnits})$"}
            target_label  = "service_name"
            replacement   = ${quote serviceName}
          }
        '';
      alloyConfig = ''
        discovery.relabel "system_journal" {
          targets = []

          rule {
            source_labels = ["__journal__systemd_user_unit"]
            regex         = ${quote ".+"}
            action        = "drop"
          }

          rule {
            source_labels = ["__journal_user_unit"]
            regex         = ${quote ".+"}
            action        = "drop"
          }

          // A single combined keep is the OR across journal unit fields.
          rule {
            source_labels = ["__journal__systemd_unit", "__journal_unit", "__journal_coredump_unit"]
            separator     = ";"
            regex         = ${quote combinedUnitRegex}
            action        = "keep"
          }

          // Set the canonical allowed unit deterministically: _SYSTEMD_UNIT,
          // then UNIT only while unit is blank, then COREDUMP_UNIT likewise.
          rule {
            source_labels = ["__journal__systemd_unit"]
            regex         = ${quote allowedUnitRegex}
            target_label  = "unit"
            replacement   = "$1"
          }

          rule {
            source_labels = ["__journal_unit", "unit"]
            separator     = ";"
            regex         = ${quote allowedMissingUnitRegex}
            target_label  = "unit"
            replacement   = "$1"
          }

          rule {
            source_labels = ["__journal_coredump_unit", "unit"]
            separator     = ";"
            regex         = ${quote allowedMissingUnitRegex}
            target_label  = "unit"
            replacement   = "$1"
          }

          rule {
            target_label = "host"
            replacement  = ${quote hostRegistry.${hostName}.hostName}
          }

          rule {
            source_labels = ["__journal_priority_keyword"]
            target_label  = "level"
          }

          ${lib.concatStringsSep "\n" (lib.mapAttrsToList serviceRule sourceServices)}
        }

        loki.source.journal "system" {
          max_age       = "12h"
          relabel_rules = discovery.relabel.system_journal.rules
          forward_to    = [loki.process.redact.receiver]
        }

        loki.process "redact" {
          stage.replace {
            expression = ${quote "(?i)(?:bearer\\x20+)([A-Za-z0-9._~+/-]+=*)"}
            replace    = "[REDACTED]"
          }

          stage.replace {
            expression = ${quote "(?i)(?:authorization|token|password|secret|api[_-]?key)(?:[\\\"'=:\\x20]+)([^,;]+)"}
            replace    = "[REDACTED]"
          }

          stage.replace {
            expression = ${quote "(bot[0-9]+:[A-Za-z0-9_-]+)"}
            replace    = "[REDACTED]"
          }

          forward_to = [loki.write.ingress.receiver]
        }

        loki.write "ingress" {
          endpoint {
            url                 = ${quote "https://${journal.ingress.fqdn}:${toString journal.ingress.port}/loki/api/v1/push"}
            batch_size          = "256KiB"
            min_backoff_period  = "500ms"
            max_backoff_period  = "5m"
            max_backoff_retries = 10

            basic_auth {
              username      = ${quote clientUsername}
              password_file = ${quote credentialPath}
            }

            tls_config {
              server_name = ${quote journal.ingress.fqdn}
            }
          }
        }
      '';
    in
    { config, lib, ... }:
    let
      unitEnabled =
        unit:
        let
          serviceName = lib.removeSuffix ".service" unit;
          service = config.systemd.services.${serviceName} or null;
        in
        service != null && (if builtins.hasAttr "enable" service then service.enable else true);
    in
    {
      assertions = [
        {
          assertion = hostRegistry.${hostName}.isNixOS;
          message = "${hostName} journal export requires a NixOS/systemd source host.";
        }
        {
          assertion = client != null;
          message = "${hostName} declares journal sources but is not enrolled as a journal client.";
        }
        {
          assertion = sourceServices != { };
          message = "${hostName} journal source declaration must contain at least one logical service.";
        }
        {
          assertion = lib.all (name: builtins.match "[A-Za-z][A-Za-z0-9_-]*" name != null) (
            builtins.attrNames sourceServices
          );
          message = "${hostName} journal service keys must be bounded logical service_name labels.";
        }
        {
          assertion = lib.all (
            source: source.units != [ ] && lib.length source.units == lib.length (lib.unique source.units)
          ) (builtins.attrValues sourceServices);
          message = "${hostName} journal source services must contain unique exact .service units.";
        }
        {
          assertion = lib.length allUnits == lib.length (lib.unique allUnits);
          message = "${hostName} maps one journal unit to more than one logical service_name.";
        }
        {
          assertion = lib.all (unit: !lib.hasSuffix "@.service" unit && !lib.hasPrefix "user@" unit) allUnits;
          message = "${hostName} journal sources require concrete system-service units; bare templates and user-manager units are unsupported.";
        }
        {
          assertion = lib.all unitEnabled allUnits;
          message = "${hostName} journal units must exist and be enabled in final config.systemd.services; package/runtime-generated units remain unsupported.";
        }
      ];

      networking.hosts = lib.optionalAttrs (enabled && hubAddress != null) {
        "${hubAddress}" = [ journal.ingress.fqdn ];
      };

      age.secrets = lib.mkIf (enabled && passwordAvailable) {
        ${clientPasswordSecret} = {
          file = passwordAgeFile;
          owner = "root";
          group = "root";
          mode = "0400";
        };
      };

      services.alloy = lib.mkIf enabled {
        enable = true;
        configPath = "/etc/alloy/config.alloy";
        extraFlags = [
          "--storage.path=/var/lib/alloy"
          "--disable-reporting"
        ];
      };
      environment.etc."alloy/config.alloy" = lib.mkIf enabled {
        text = alloyConfig;
        mode = "0444";
      };
      systemd.services.alloy = lib.mkIf enabled {
        onFailure = [ "notify-telegram@%n.service" ];
        serviceConfig.LoadCredential = [ "${credentialName}:${passwordRuntimePath}" ];
        unitConfig.ConditionPathExists = [ passwordRuntimePath ];
      };
    };
in
{
  configurations.nixos = lib.mapAttrs (hostName: sourceServices: {
    module = sourceModule hostName sourceServices;
  }) supportedSources;
}

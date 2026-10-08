{
  host,
  grafanaHost,
  logPanelId,
}:
let
  select = ''job="${host}-node",instance="${host}"'';
  eligible = "games:alert_eligible{${select}}";
  gate = "and on(instance,server_id) ${eligible}";
  alert = name: expression: duration: severity: summary: description: {
    alert = name;
    expr = expression;
    for = duration;
    labels = { inherit severity; };
    annotations = {
      inherit summary description;
      dashboard = "https://${grafanaHost}/d/game-servers/game-servers?var-server={{ $labels.server_id }}";
      logs = "https://${grafanaHost}/d/game-servers/game-servers?var-server={{ $labels.server_id }}&viewPanel=${toString logPanelId}";
    };
  };
in
{
  groups = [
    {
      name = "games";
      interval = "30s";
      rules = [
        {
          record = "games:alert_eligible";
          expr = ''
            (games_server_enabled{${select}} == 1)
            and on(instance,server_id) (games_metrics_collection_success{${select}} == 1)
            and on(instance) (time() - games_metrics_last_update_timestamp_seconds{${select}} < 180)
            and on(instance) (up{${select}} == 1)
          '';
        }
        (alert "GameServerFailed" ''(games_server_failed{${select},server_id!="velocity"} == 1) ${gate}''
          "5m"
          "critical"
          "Game {{ $labels.server_id }} failed on {{ $labels.host }}"
          "Inspect the game journal and clean-exit proof. Normal sleep and deliberate clean stops do not fire this alert."
        )
        (alert "VelocityDown" ''(games_server_ready{${select},server_id="velocity"} == 0) ${gate}'' "5m"
          "critical"
          "Velocity is down on {{ $labels.host }}"
          "The enabled proxy has not answered its local status query for five minutes. Inspect its unit and journal."
        )
        (alert "GameBackupUnhealthy"
          ''
            (
              (games_backup_failed{${select}} == 1)
              or
              (time() - (
                games_backup_enabled_timestamp_seconds{${select}}
                + clamp_min(games_backup_last_success_timestamp_seconds{${select}}
                  - games_backup_enabled_timestamp_seconds{${select}}, 0)
              ) > 172800)
            )
            and on(instance,server_id) (games_backup_configured{${select}} == 1)
            ${gate}
          ''
          "5m"
          "critical"
          "Game {{ $labels.server_id }} backup needs attention"
          "The latest attempt failed, including recovery, or no successful world snapshot has completed in 48 hours. Newly enabled backups have a 48-hour grace period."
        )
        (alert "GameServerMemoryPressure"
          ''
            ((games_memory_current_bytes{${select},scope="server"}
              / games_memory_limit_bytes{${select},scope="server"}) > 0.90)
            ${gate}
          ''
          "15m"
          "warning"
          "Game {{ $labels.server_id }} memory exceeds 90% of MemoryMax"
          "Memory has remained above 90% for fifteen minutes. Inspect usage before raising the declarative limit; this warning does not page."
        )
      ];
    }
  ];
}

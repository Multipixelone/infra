{ lib, ... }:
let
  viz = import ../../lib/grafana.nix { inherit lib; };
  selector = ''job="link-node",instance="link",server_id=~"$server"'';
  fresh = ''and on(instance) (time() - games_metrics_last_update_timestamp_seconds{job="link-node",instance="link"} < 180)'';
  valid = "and on(instance,server_id) (games_metrics_collection_success{${selector}} == 1) ${fresh}";
  mapping = values: [
    {
      type = "value";
      options = values;
    }
  ];
  stateExpression = ''
    sum without(state) (
      games_server_state{${selector},state="running"} * 2
      or games_server_state{${selector},state="sleeping"}
      or games_server_state{${selector},state="disabled"} * 3
      or games_server_state{${selector},state="stopped"} * 0
    ) ${valid}
  '';
  stateMappings = mapping {
    "0" = {
      text = "Stopped";
      color = "text";
      index = 0;
    };
    "1" = {
      text = "Sleeping";
      color = "blue";
      index = 1;
    };
    "2" = {
      text = "Running";
      color = "green";
      index = 2;
    };
    "3" = {
      text = "Disabled";
      color = "text";
      index = 3;
    };
  };
  series =
    title: expression: unit:
    viz.panel {
      inherit title unit;
      expr = expression;
      legend = "{{server_id}}";
    };
  table =
    title: targets: unit:
    viz.panel {
      inherit title unit;
      type = "table";
      w = 24;
      targets = map (
        target:
        target
        // {
          expr = "max by(server_id) (${target.expr})";
          instant = true;
          format = "table";
        }
      ) targets;
      transformations = [
        {
          id = "joinByField";
          options = {
            byField = "server_id";
            mode = "outerTabular";
          };
        }
        {
          id = "organize";
          options = {
            excludeByName = lib.listToAttrs (
              lib.concatMap
                (
                  name:
                  map (suffix: lib.nameValuePair "${name}${suffix}" true) (
                    [ "" ] ++ map (index: " ${toString index}") (lib.range 1 (builtins.length targets))
                  )
                )
                [
                  "Time"
                  "__name__"
                ]
            );
            renameByName = {
              server_id = "Server";
            }
            // lib.listToAttrs (
              lib.imap0 (
                index: target:
                lib.nameValuePair "Value #${builtins.elemAt [ "A" "B" "C" "D" "E" "F" ] index}" target.legend
              ) targets
            );
          };
        }
      ];
    };
  dashboard = viz.dashboard {
    uid = "game-servers";
    title = "Game Servers";
    tags = [
      "games"
      "provisioned"
    ];
    description = "Game state, activity, resources, backups and journals. Sleeping Paper is never queried. Missing telemetry is unknown.";
    templating.list = [
      {
        name = "server";
        label = "Server";
        type = "query";
        datasource = {
          type = "prometheus";
          uid = "prometheus";
        };
        query = ''label_values(games_server_enabled{job="link-node",instance="link"}, server_id)'';
        definition = ''label_values(games_server_enabled{job="link-node",instance="link"}, server_id)'';
        refresh = 1;
        multi = true;
        includeAll = true;
        allValue = ".*";
        current = {
          text = "All";
          value = "$__all";
        };
        sort = 1;
      }
      {
        name = "event";
        label = "Log event";
        type = "custom";
        query = "join,leave,chat,console,sleep,wake";
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
      [ (viz.row "State and activity") ]
      [
        (viz.panel {
          title = "Server state";
          type = "state-timeline";
          w = 24;
          expr = stateExpression;
          legend = "{{server_id}}";
          mappings = stateMappings;
          description = "Stopped includes deliberate clean stops. A confirmed failure appears in the failure panel. Gaps mean unavailable or stale state telemetry.";
        })
      ]
      [
        (table "Readiness, failures and telemetry" [
          {
            expr = "games_server_ready{${selector}} ${valid}";
            legend = "Ready";
          }
          {
            expr = "games_server_failed{${selector}} ${valid}";
            legend = "Confirmed failure";
          }
          {
            expr = "games_metrics_collection_success{${selector}} ${fresh}";
            legend = "State collection";
          }
          {
            expr = "games_players_known{${selector}} ${valid}";
            legend = "Player count known";
          }
          {
            expr = "games_journal_collection_success{${selector}} ${fresh}";
            legend = "Journal collection";
          }
        ] viz.units.none)
      ]
      [
        (viz.panel {
          title = "Players and capacity";
          unit = viz.units.none;
          decimals = 0;
          description = "Terraria is a journal-derived estimate and stays unknown without complete startup history. Velocity has no enforced player cap. Sleeping Paper has zero players.";
          targets = [
            {
              expr = "games_players_online{${selector}} ${valid}";
              legend = "{{server_id}} players";
            }
            {
              expr = "games_player_capacity{${selector}} ${valid}";
              legend = "{{server_id}} capacity";
            }
          ];
        })
        (series "Workload uptime" "(time() - games_server_start_time_seconds{${selector}}) ${valid}"
          viz.units.duration
        )
      ]
      [
        (viz.panel {
          title = "Joins and leaves";
          unit = viz.units.ops;
          targets =
            map
              (event: {
                expr = ''rate(games_player_events_total{${selector},event="${event}"}[$__rate_interval]) ${valid}'';
                legend = "{{server_id}} ${event}";
              })
              [
                "join"
                "leave"
              ];
          description = "Observed journal events, not unique players or session duration. Counter coverage is bounded by retained journal history.";
        })
        (viz.panel {
          title = "Sleep and wake events";
          unit = viz.units.short;
          targets =
            map
              (event: {
                expr = ''increase(games_lazymc_events_total{${selector},event="${event}"}[4m]) ${valid}'';
                legend = "{{server_id}} ${event}";
              })
              [
                "sleep"
                "wake"
              ];
        })
      ]
      [
        (table "Activity during selected range" [
          {
            expr = ''increase(games_player_events_total{${selector},event="join"}[$__range]) ${valid}'';
            legend = "Joins";
          }
          {
            expr = ''increase(games_player_events_total{${selector},event="leave"}[$__range]) ${valid}'';
            legend = "Leaves";
          }
        ] viz.units.short)
      ]
      [ (viz.row "Resources") ]
      [
        (series "CPU usage (cores)"
          ''rate(games_cpu_seconds_total{${selector},scope="server"}[$__rate_interval]) ${valid}''
          viz.units.none
        )
        (viz.panel {
          title = "RAM and MemoryMax";
          unit = viz.units.bytes;
          targets = [
            {
              expr = ''games_memory_current_bytes{${selector},scope="server"} ${valid}'';
              legend = "{{server_id}} RAM";
            }
            {
              expr = ''games_memory_limit_bytes{${selector},scope="server"} ${valid}'';
              legend = "{{server_id}} MemoryMax";
            }
          ];
        })
      ]
      [
        (series "Memory limit used"
          ''100 * games_memory_current_bytes{${selector},scope="server"} / games_memory_limit_bytes{${selector},scope="server"} ${valid}''
          viz.units.percent
        )
        (viz.panel {
          title = "World I/O";
          unit = viz.units.bytesPerSecond;
          targets = [
            {
              expr = ''rate(games_io_read_bytes_total{${selector},scope="server"}[$__rate_interval]) ${valid}'';
              legend = "{{server_id}} read";
            }
            {
              expr = ''rate(games_io_write_bytes_total{${selector},scope="server"}[$__rate_interval]) ${valid}'';
              legend = "{{server_id}} write";
            }
          ];
        })
      ]
      [
        (viz.panel {
          title = "games.slice CPU";
          unit = viz.units.none;
          expr = ''rate(games_cpu_seconds_total{job="link-node",instance="link",scope="slice"}[$__rate_interval]) ${fresh}'';
          legend = "games.slice";
          description = "Whole-slice total; do not add it to the individual server totals.";
        })
        (viz.panel {
          title = "games.slice RAM";
          unit = viz.units.bytes;
          expr = ''games_memory_current_bytes{job="link-node",instance="link",scope="slice"} ${fresh}'';
          legend = "games.slice";
        })
      ]
      [
        (series "tModLoader container CPU"
          ''rate(games_cpu_seconds_total{${selector},scope="container"}[$__rate_interval]) ${valid}''
          viz.units.none
        )
        (series "tModLoader container RAM"
          ''games_memory_current_bytes{${selector},scope="container"} ${valid}''
          viz.units.bytes
        )
      ]
      [
        (viz.panel {
          title = "tModLoader container I/O";
          unit = viz.units.bytesPerSecond;
          w = 24;
          targets = [
            {
              expr = ''rate(games_io_read_bytes_total{${selector},scope="container"}[$__rate_interval]) ${valid}'';
              legend = "{{server_id}} read";
            }
            {
              expr = ''rate(games_io_write_bytes_total{${selector},scope="container"}[$__rate_interval]) ${valid}'';
              legend = "{{server_id}} write";
            }
          ];
        })
      ]
      [ (viz.row "World backups") ]
      [
        (lib.recursiveUpdate
          (table "Backup configuration and outcome" [
            {
              expr = "games_backup_configured{${selector}} ${valid}";
              legend = "Configured";
            }
            {
              expr = "games_backup_failed{${selector}} and on(instance,server_id) (games_backup_configured{${selector}} == 1) ${valid}";
              legend = "Last attempt failed";
            }
            {
              expr = "games_backup_in_progress{${selector}} and on(instance,server_id) (games_backup_configured{${selector}} == 1) ${valid}";
              legend = "In progress";
            }
            {
              expr = "games_backup_last_success_timestamp_seconds{${selector}} * 1000 ${valid}";
              legend = "Last snapshot";
            }
          ] viz.units.none)
          {
            description = "Configured=0 means Not configured, not failing. History remains available after disabling backups.";
            fieldConfig.overrides = [
              {
                matcher = {
                  id = "byName";
                  options = "Configured";
                };
                properties = [
                  {
                    id = "mappings";
                    value = viz.boolMapping {
                      falseText = "Not configured";
                      trueText = "Configured";
                      falseColor = "text";
                    };
                  }
                ];
              }
              {
                matcher = {
                  id = "byName";
                  options = "Last snapshot";
                };
                properties = [
                  {
                    id = "unit";
                    value = viz.units.dateTimeAsIso;
                  }
                  {
                    id = "mappings";
                    value = mapping {
                      "0" = {
                        text = "Never succeeded";
                        color = "text";
                        index = 0;
                      };
                    };
                  }
                ];
              }
            ];
          }
        )
      ]
      [
        (series "Backup age"
          "(time() - games_backup_last_success_timestamp_seconds{${selector}} > 0) and on(instance,server_id) (games_backup_configured{${selector}} == 1) and on(instance,server_id) (games_backup_last_success_timestamp_seconds{${selector}} > 0) ${valid}"
          viz.units.duration
        )
        (series "Successful backup duration" "games_backup_last_duration_seconds{${selector}} ${valid}"
          viz.units.duration
        )
      ]
      [
        (series "Last snapshot size" "games_backup_last_size_bytes{${selector}} ${valid}" viz.units.bytes)
        (viz.panel {
          title = "Minecraft detail and editions";
          type = "text";
          options = {
            mode = "markdown";
            content = "TPS/MSPT, chunks, entities and JVM heap: **Unavailable** (no metrics plugin installed). RAM panels show cgroup memory.\n\nVelocity readiness and connected players appear above. Java/Bedrock split: **Unavailable**.";
          };
        })
      ]
      [ (viz.row "Game journals") ]
      [
        (viz.panel {
          title = "Recent game logs";
          type = "logs";
          datasource = "loki";
          w = 24;
          h = 12;
          expr = ''{host="link",service_name="games",server_id=~"$server",event=~"$event"}'';
          options = {
            showTime = true;
            showLabels = false;
            wrapLogMessage = true;
            sortOrder = "Descending";
          };
        })
      ]
      [
        (viz.panel {
          title = "Telemetry age";
          unit = viz.units.seconds;
          expr = ''time() - games_metrics_last_update_timestamp_seconds{job="link-node",instance="link"}'';
          legend = "link";
          w = 24;
          description = "State and resource panels leave gaps after three minutes without an updated collection.";
        })
      ]
    ];
  };
in
{
  flake.grafanaDashboards."game-servers.json" = dashboard;
  configurations.nixos.link.module = { pkgs, ... }: {
    services.grafana.provision.dashboards.settings.providers = lib.mkAfter [
      {
        name = "Game servers";
        type = "file";
        disableDeletion = true;
        allowUiUpdates = false;
        updateIntervalSeconds = 60;
        options.path = pkgs.linkFarm "grafana-game-dashboards" [
          {
            name = "game-servers.json";
            path = pkgs.writeText "game-servers.json" (builtins.toJSON dashboard);
          }
        ];
      }
    ];
  };
  perSystem = { pkgs, ... }: {
    packages.games-grafana-dashboard = pkgs.writeText "game-servers.json" (builtins.toJSON dashboard);
  };
}

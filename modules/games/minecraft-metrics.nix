{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
    in
    lib.mkIf (servers != { }) {
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: s: {
        jars.tickscope = cfg.artifacts.games-tickscope;
        inventory = [
          {
            name = "TickScope";
            version = "2.0.1";
            installed = true;
          }
        ];
        statePaths = [ "/srv/games/minecraft/${id}/plugins/TickScope" ];
        templates."/srv/games/minecraft/${id}/plugins/TickScope/config.yml".source = toString (
          (pkgs.formats.yaml { }).generate "tickscope-${id}.yml" {
            server-id = id;
            bind-address = "127.0.0.1";
            port = s.minecraft.metricsPort;
            path = "/metrics";
            collection-interval-ticks = 600;
            per-world = true;
            entity-types = {
              enabled = false;
              interval-ticks = 600;
              chunks-per-tick = 8;
              allowlist = [ ];
            };
          }
        );
      }) servers;
      services.prometheus.scrapeConfigs = [
        {
          job_name = "minecraft-paper";
          scrape_interval = "60s";
          scrape_timeout = "5s";
          static_configs = lib.mapAttrsToList (id: s: {
            targets = [ "127.0.0.1:${toString s.minecraft.metricsPort}" ];
            labels = {
              instance = "link";
              server_id = id;
              game = "minecraft-paper";
              service_name = "games";
            };
          }) servers;
          metric_relabel_configs = [
            {
              source_labels = [ "__name__" ];
              # Exact families keep entity-by-type cardinality out of Prometheus.
              # Passive games-metrics remains authoritative for lifecycle state.
              regex = "mc_(tickscope_info|tps|tick_duration_seconds|tick_samples|players_(online|max)|uptime_seconds|world_(entities|tile_entities|chunks)|jvm_(memory_(used|committed|max|init)_bytes|threads_(current|daemon|peak|started_total)|classes_loaded|gc_(collections|seconds)_total)|(?:process|system)_cpu_load_ratio|events_total|collection_(duration_seconds|enabled|last_success_timestamp_seconds|failures_total))";
              action = "keep";
            }
          ];
        }
      ];
    };
}

{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      lodPort = 25568;
      lodHost = "mc.finnrut.is";
      configuration =
        id:
        (pkgs.formats.yaml { }).generate "${id}-chunksmith-4.6.0.yml" {
          version = 2;
          language = "en";
          continue-on-restart = false;
          force-load-existing-chunks = false;
          silent = false;
          update-interval = 1;

          # Reusing Chunky's saved area still requires an operator to verify
          # the saved selection and explicitly start the first LOD backfill.
          # Only the default backend serves LODs; other backends need their own
          # explicitly allocated endpoint before enabling this feature.
          lod-enabled = lib.boolToString (id == cfg.defaultServer);
          lod-from-explored-chunks = false;
          lod-backchannel-port = lodPort;
          lod-backchannel-bind-address = "0.0.0.0";
          lod-backchannel-host = lodHost;
          lod-index-budget-mb = 0;

          # These BukkitConfig keys are supported by the pinned plugin. Keep
          # Paper's existing heap/service limits and yield early to players.
          io-throttle = true;
          dispatch-max-concurrent = 2;
          throttle-target-mspt = 54;
          throttle-tick-budget-millis = 5;
          throttle-player-reserve-millis = 30;
          throttle-ceiling-millis = 60;
          throttle-max-chunk-millis = 750;
          throttle-max-queued-writes = 100;
          throttle-max-heap-percent = 75;
          throttle-max-lod-queue = 64;
          throttle-lod-drain-to = 0;
          auto-pause-on-overload = true;
          auto-pause-grace-seconds = 30;
        };
    in
    lib.mkIf (servers != { }) {
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars.chunksmith = cfg.artifacts.games-chunksmith;
        templates."/srv/games/minecraft/${id}/plugins/Chunksmith/config.yml".source = toString (
          configuration id
        );
        # Preserve the legacy selection/task records in place, including in
        # pre-change and scheduled snapshots. Do not import/resume them here.
        statePaths = [
          "/srv/games/minecraft/${id}/plugins/Chunky"
          "/srv/games/minecraft/${id}/plugins/Chunksmith"
        ];
        publicTCPPorts = lib.optional (id == cfg.defaultServer) lodPort;
        publicEndpoints = lib.optional (id == cfg.defaultServer) {
          hostname = lodHost;
          port = lodPort;
          protocol = "tcp";
          edition = "LOD";
        };
        inventory = [
          {
            name = "Chunksmith";
            version = "4.6.0+26.x-plugin";
            installed = true;
          }
        ];
      }) servers;
      # No generation, refresh, resume, task migration or area-selection hook.
      # CSLOD lives beneath each backed-up world directory. Backend bStats is
      # already disabled; this artifact has no runtime updater/downloader.
    };
}

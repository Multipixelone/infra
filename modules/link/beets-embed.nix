{
  config,
  inputs,
  lib,
  rootPath,
  withSystem,
  ...
}:
let
  owner = config.flake.meta.owner.username;
  launcher = import ../../lib/beets-embed-launcher.nix;
in
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.beets-embed-backfill =
        inputs.beets-plugins.inputs.nixpkgs.legacyPackages.${system}.python3Packages.callPackage
          "${rootPath}/pkgs/beets-embed-backfill"
          {
            beets = inputs.beets-plugins.packages.${system}.default;
            listen = withSystem system (args: args.config.packages.listen);
          };
      checks.beets-embed-window =
        let
          fixture = pkgs.writeShellApplication {
            name = "beets-embed-window-fixture";
            runtimeInputs = [ pkgs.coreutils ];
            text = launcher;
          };
        in
        pkgs.runCommand "beets-embed-window-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
          export PYTHONDONTWRITEBYTECODE=1
          export TZDIR=${pkgs.tzdata}/share/zoneinfo
          python3 ${./tests/beets_embed_window_test.py} ${lib.getExe fixture}
          touch "$out"
        '';
    };

  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      cfg = config.services.beets.embedBackfill;
      home = config.home-manager.users.${owner};
      store = home.programs.beets.settings.embed.store;
      storeDirectory = builtins.dirOf store;
      package = withSystem pkgs.stdenv.hostPlatform.system (
        args: args.config.packages.beets-embed-backfill
      );
      jobConfig = pkgs.writeText "beets-embed-backfill.json" (
        builtins.toJSON {
          library = home.programs.beets.settings.library;
          directory = home.programs.beets.settings.directory;
          inherit store;
        }
      );
      run = pkgs.writeShellApplication {
        name = "beets-embed-backfill";
        runtimeInputs = [
          pkgs.coreutils
          inputs.beets-plugins.packages.${pkgs.stdenv.hostPlatform.system}.beets-embed-worker-rocm
        ];
        text = ''
          export BEETS_EMBED_BUDGET_SECONDS=${toString (cfg.budgetHours * 3600)}
          export BEETS_EMBED_THREADS=${toString cfg.threads}
          export BEETS_EMBED_CONFIG=${lib.escapeShellArg jobConfig}
          export BEETS_EMBED_RUNNER=${lib.escapeShellArg (lib.getExe package)}
          ${launcher}
        '';
      };
    in
    {
      options.services.beets = {
        embedBackfill = {
          enable = lib.mkEnableOption ''
            concurrent nightly read-only embedding backfill.
            After replacing the CPU and revalidating the worker, stop
            beets-embed-backfill and beets-album-graph-export services and timers.
            With the store's .backfill.lock held exclusively, archive or remove
            embeddings.sqlite3 and its -wal/-shm sidecars, then restart timers.
            The next nights recompute both families; the import lock is unnecessary
          '';
          budgetHours = lib.mkOption {
            type = lib.types.ints.between 1 8;
            default = 8;
            description = "Maximum elapsed nightly budget, including shutdown; always finish before 09:00 America/New_York.";
          };
          threads = lib.mkOption {
            type = lib.types.ints.between 1 16;
            default = lib.min 16 (lib.max 1 (builtins.div config.link.cpu.threads 8));
            description = "Native ONNX/Torch inference threads; preparation uses one worker and FFmpeg one decode thread.";
          };
          cpuQuotaPercent = lib.mkOption {
            type = lib.types.ints.positive;
            default = config.services.beets.embedBackfill.threads * 100;
            description = "Aggregate systemd CPU quota for embedding, preparation and all descendants; 100 is one logical CPU.";
          };
        };
        xtractorBackfill = {
          workers = lib.mkOption {
            type = lib.types.ints.positive;
            default = lib.max 1 (builtins.div (config.link.cpu.threads * 3) 8);
            description = "Nightly xt -t concurrency: maximum simultaneous Essentia subprocesses. Zero/automatic CPU detection is disallowed.";
          };
          cpuQuotaPercent = lib.mkOption {
            type = lib.types.ints.positive;
            default = 100 * lib.max 1 (builtins.div config.link.cpu.threads 4);
            description = "Aggregate systemd CPU quota for the nightly xtractor worker tree; independent of its worker count.";
          };
        };
      };

      config = {
        services.beets.embedBackfill.enable = lib.mkDefault true;
        systemd.tmpfiles.rules = lib.mkIf cfg.enable [
          "d ${storeDirectory} 0700 ${owner} users - -"
        ];
        systemd.services.beets-embed-backfill = lib.mkIf cfg.enable {
          description = "Backfill Style and Text embeddings without locking beets imports";
          after = [ "systemd-tmpfiles-setup.service" ];
          requires = [ "beets-nightly.target" ];
          partOf = [ "beets-nightly.target" ];
          environment = {
            HOME = home.home.homeDirectory;
            XDG_CACHE_HOME = "/tmp/beets-embed-cache";
            MIOPEN_CUSTOM_CACHE_DIR = "/tmp/beets-embed-cache/miopen";
            MIOPEN_USER_DB_PATH = "/tmp/beets-embed-cache/miopen-db";
            PYTHONDONTWRITEBYTECODE = "1";
            TZDIR = "${pkgs.tzdata}/share/zoneinfo";
          };
          serviceConfig = {
            Type = "exec";
            User = owner;
            Slice = "batch-beets.slice";
            SupplementaryGroups = [
              "render"
              "video"
            ];
            ExecStart = lib.getExe run;
            RuntimeMaxSec = "${toString cfg.budgetHours}h";
            CPUQuota = "${toString cfg.cpuQuotaPercent}%";
            Nice = 10;
            CPUWeight = 10;
            IOSchedulingClass = "idle";
            KillSignal = "SIGTERM";
            KillMode = "control-group";
            TimeoutStopSec = "60s";
            SuccessExitStatus = [
              "124"
              "143"
            ];
            Restart = "no";
            UMask = "0077";
            NoNewPrivileges = true;
            CapabilityBoundingSet = "";
            PrivateTmp = true;
            # PrivateDevices would hide the GPU and force CPU fallback.
            PrivateDevices = false;
            DevicePolicy = "closed";
            DeviceAllow = [
              "/dev/kfd rw"
              "char-drm rw"
            ];
            ProtectSystem = "strict";
            ProtectHome = "read-only";
            ReadOnlyPaths = [
              home.programs.beets.settings.directory
              (builtins.dirOf home.programs.beets.settings.library)
            ];
            ReadWritePaths = [ storeDirectory ];
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            RestrictNamespaces = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            PrivateNetwork = true;
            RestrictAddressFamilies = [ "AF_UNIX" ];
          };
        };
        systemd.timers.beets-embed-backfill = lib.mkIf cfg.enable {
          description = "Schedule the concurrent nightly embedding backfill";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 01:00:00 America/New_York";
            Persistent = false;
            RandomizedDelaySec = 0;
            AccuracySec = "1s";
          };
        };
        systemd.services.beets-embed-backfill-stop = lib.mkIf cfg.enable {
          description = "Stop nightly embeddings before 09:00 local, including after resume";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${lib.getExe' pkgs.systemd "systemctl"} stop beets-embed-backfill.service";
            TimeoutStartSec = "90s";
          };
        };
        systemd.timers.beets-embed-backfill-stop = lib.mkIf cfg.enable {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "*-*-* 08:58:59 America/New_York";
            Persistent = false;
            RandomizedDelaySec = 0;
            AccuracySec = "1s";
          };
        };
      };
    };
}

{ config, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      host = config.flake.nixosConfigurations.link;
      project =
        cfg:
        let
          jobs = [
            "beets-xtractor-backfill"
          ]
          ++ lib.optional cfg.services.beets.embedBackfill.enable "beets-embed-backfill";
          names = [
            "batch.slice"
            "batch-ci.slice"
            "batch-nix.slice"
            "batch-beets.slice"
            "beets-nightly.target"
            "beets-nightly-now.target"
          ]
          ++ lib.concatMap (
            job:
            map (suffix: "${job}${suffix}") [
              ".service"
              "-now.service"
              ".timer"
              "-stop.service"
              "-stop.timer"
            ]
          ) jobs;
        in
        {
          inherit jobs;
          beetsSlices = lib.filter (lib.hasInfix "beets") (builtins.attrNames cfg.systemd.slices);
          slices = lib.mapAttrs (_: slice: slice.sliceConfig) (
            lib.getAttrs [ "batch" "batch-ci" "batch-nix" "batch-beets" ] cfg.systemd.slices
          );
          workers = cfg.services.beets.xtractorBackfill.workers;
          threads = cfg.services.beets.embedBackfill.threads;
          transcodeService = cfg.home-manager.users.tunnel.systemd.user.services.transcode-music.Service;
          runtimeDirectorySize = cfg.services.logind.settings.Login.RuntimeDirectorySize or "10%";
          kernelVersion = cfg.boot.kernelPackages.kernel.version;
          tmpfiles = cfg.systemd.tmpfiles.rules;
          manualTimers = lib.filter (lib.hasSuffix "-now") (builtins.attrNames cfg.systemd.timers);
          units = lib.genAttrs names (name: cfg.systemd.units.${name}.text);
        };
      fixtureData = {
        default = project host.config;
        memoryHigh =
          project
            (host.extendModules {
              modules = [ { services.beets.nightly.memoryHigh = "8G"; } ];
            }).config;
        quotaOverrides =
          project
            (host.extendModules {
              modules = [
                {
                  services.beets.xtractorBackfill.cpuQuotaPercent = 700;
                  services.beets.embedBackfill.cpuQuotaPercent = 300;
                }
              ];
            }).config;
        embedDisabled =
          project
            (host.extendModules {
              modules = [ { services.beets.embedBackfill.enable = false; } ];
            }).config;
      };
      modeLock = import ../../lib/beets-backfill-mode-lock.nix { inherit pkgs; };
      fixture = pkgs.writeText "link-beets-nightly-fixtures.json" (builtins.toJSON fixtureData);
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.link-beets-nightly =
        pkgs.runCommand "link-beets-nightly-check"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.systemd
              pkgs.coreutils
              pkgs.proot
            ];
            # Allow the same evaluated cases to be checked without building a check.
            passthru = { inherit fixtureData; };
          }
          ''
            export PYTHONDONTWRITEBYTECODE=1
            # Newer systemd verifies with a manager runtime directory even in
            # test mode. Supply private /run and timezone data inside the Nix
            # sandbox while retaining system-manager dependency verification.
            mkdir -p "$TMPDIR/test-run"
            proot -b "$TMPDIR/test-run:/run" \
              -b ${pkgs.tzdata}/share/zoneinfo:/etc/zoneinfo \
              python3 ${./tests/beets_nightly_units_test.py} ${fixture}
            python3 ${./tests/beets_backfill_mode_lock_test.py} ${lib.getExe modeLock}
            touch "$out"
          '';
    };
}

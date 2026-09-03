{ inputs, ... }:
let
  runnerSecret = "${inputs.secrets}/forgejo/runner-link.age";
  # The registration credential only exists once Forgejo is running, so the
  # whole instance stays off until the .age lands. Guarded rather than
  # unconditionally enabled because a runner that cannot register retries
  # forever and buries the journal.
  hasRunnerSecret = builtins.pathExists runnerSecret;
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
      # Cores 6 and 7 with their SMT siblings — verified against lscpu -e on
      # link, where siblings are (n, n+8). The game keeps 0-5 and 8-13.
      ciCpus = "6,7,14,15";

      throttle = pkgs.writeShellApplication {
        name = "forgejo-ci-throttle";
        runtimeInputs = [ pkgs.systemd ];
        text = ''
          # Nix builders are forked by nix-daemon.service, not by the runner
          # unit, so they land in a different cgroup entirely. Fencing only the
          # runner would leave the actual compile work unconstrained.
          systemctl set-property --runtime ci.slice           CPUWeight=1 IOWeight=1 AllowedCPUs=${ciCpus}
          systemctl set-property --runtime nix-daemon.service CPUWeight=1 IOWeight=1 AllowedCPUs=${ciCpus}
        '';
      };

      unthrottle = pkgs.writeShellApplication {
        name = "forgejo-ci-unthrottle";
        runtimeInputs = [ pkgs.systemd ];
        text = ''
          # An empty AllowedCPUs= resets the mask to every CPU.
          systemctl set-property --runtime ci.slice           CPUWeight=20  IOWeight=20  AllowedCPUs=
          systemctl set-property --runtime nix-daemon.service CPUWeight=100 IOWeight=100 AllowedCPUs=
        '';
      };
    in
    {
      age.secrets = lib.mkIf hasRunnerSecret {
        "forgejo-runner-link" = {
          file = runnerSecret;
          # Read by systemd as root and handed to the unit through
          # LoadCredential=; the unit's DynamicUser does not exist at
          # activation time, so it could not own this anyway.
          owner = "root";
          group = "root";
          mode = "0400";
        };
      };

      # Guarded as a whole, not just via `enable`. Declaration and consumer
      # have to move together: token_url dereferences
      # age.secrets."forgejo-runner-link".path, and an `enable = false`
      # instance still evaluates that reference against an attrset the
      # secret's own mkIf has removed.
      services.forgejo-runner.instances.link = lib.mkIf hasRunnerSecret {
        enable = true;
        # Dash-free instance name on purpose: the module runs the name through
        # utils.escapeSystemdPath, which would turn a dash into \x2d and make
        # the unit name unpleasant to type.
        settings = {
          log.level = "info";
          runner = {
            # `<anything>:host` turns on native execution. A docker/podman
            # label would run jobs in a container with no /nix and no daemon
            # socket, so every Nix build would either fail or need the store
            # bind-mounted back in — which is the host runtime with extra
            # steps. Podman is enabled on link, so this would have silently
            # "worked" and simply been useless.
            labels = [ "nix:host" ];
            capacity = 2;
            # Forgejo and the runner both default to 3h, which would kill the
            # host-closure matrix at the same wall-clock every time and read as
            # a build failure. Matches actions.timeout.DEFAULT on impa.
            timeout = "8h";
            # Report an interrupted task rather than holding a reboot open;
            # anything unreported is reaped server-side as a zombie task.
            shutdown_timeout = "30s";
            fetch_interval = "5s";
            envs = {
              # Client-side, so CI builds are bounded without slowing the
              # interactive `just rebuild` path on the same machine.
              NIX_CONFIG = "max-jobs = 3\ncores = 4";
            };
          };
          # Nix and attic are the cache. The built-in Actions cache would only
          # add a listening socket on the LAN.
          cache.enabled = false;
          host.workdir_parent = "/var/lib/forgejo-runner/link/work";
          server.connections.default = {
            # The canonical name, not forgejo.nyc.finnrut.is — that alias is now
            # a vhost returning 308, and pointing the Actions API at a
            # redirecting host is a bad bet. Blocky resolves this to impa's LAN
            # address, so the runner still never leaves the network.
            url = "https://git.finnrut.is";
            # REPLACE when the runner is registered: the POST to
            # /api/v1/repos/Multipixelone/infra/actions/runners returns both a
            # uuid and a token. The uuid is an identifier, not an
            # authenticator, so it belongs in the store; the token does not.
            # The module has no uuid_url yet (upstream FIXME), so this is
            # literal by necessity.
            uuid = "00000000-0000-0000-0000-000000000000";
          };
        };
        secrets.server.connections.default.token_url = config.age.secrets."forgejo-runner-link".path;

        # The default set is bash/coreutils/curl/gawk/gnused/nodejs/wget, and
        # gitMinimal is always added. Neither nix nor jq is present, and this
        # repo's workflows are nothing but nix.
        hostPackages = with pkgs; [
          bash
          coreutils
          curl
          gawk
          gnused
          nodejs
          wget
          config.nix.package
          attic-client
          jq
          gnutar
          gzip
          xz
          zstd
          findutils
          gnugrep
          openssh
          which
        ];
      };

      systemd.slices.ci.sliceConfig = {
        # user.slice sits at the default weight of 100, and that is where the
        # game runs. A whole-flake `nix eval` runs in the client process, i.e.
        # inside this slice, and is the likeliest thing to OOM Grafana and
        # Prometheus on a box that is already memory-tight.
        CPUWeight = 20;
        IOWeight = 20;
        MemoryHigh = "8G";
        MemoryMax = "12G";
        TasksMax = 4096;
      };

      systemd.services."forgejo-runner-link" = lib.mkIf hasRunnerSecret {
        onFailure = [ "notify-telegram@%n.service" ];
        serviceConfig = {
          Slice = "ci.slice";
          Nice = 10;
          IOSchedulingClass = "idle";
          TimeoutStopSec = 60;
        };
      };

      systemd.services.forgejo-ci-throttle = {
        description = "Fence CI onto two cores while a game is running";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe throttle;
        };
      };

      systemd.services.forgejo-ci-unthrottle = {
        description = "Release the CI CPU fence";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe unthrottle;
        };
      };

      # gamemode's custom start/end hooks run as tunnel, so they need
      # permission to start these two units. Same shape as the
      # podman-nicotine rule in modules/link/nicotine.nix.
      security.polkit = {
        enable = true;
        extraConfig = ''
          polkit.addRule(function(action, subject) {
              if (action.id == "org.freedesktop.systemd1.manage-units") {
                  var unit = action.lookup("unit");
                  if (unit == "forgejo-ci-throttle.service" || unit == "forgejo-ci-unthrottle.service") {
                      if (action.lookup("verb") == "start") {
                          return polkit.Result.YES;
                      }
                  }
              }
          });
        '';
      };

      nix.settings = {
        # The repo sets abort-on-warn = true globally, and flake.nix carries
        # nixConfig.extra-substituters. For an untrusted client Nix warns that
        # it is ignoring those settings, and that warning is then fatal — so an
        # untrusted runner cannot build this flake at all. Turning abort-on-warn
        # off is not the fix: the warning is true, and CI would just build
        # slowly without the flake's substituters. The blast radius is bounded
        # by registering the runner at repository scope rather than globally.
        trusted-users = [ "forgejo-runner-link" ];
        # /nix on link runs close to full and is shared with the game library.
        # Same lever modules/ci.nix already uses on the GitHub runners: collect
        # garbage as the build fills the disk instead of dying at zero.
        min-free = 10 * 1024 * 1024 * 1024;
        max-free = 40 * 1024 * 1024 * 1024;
      };
      nix.daemonCPUSchedPolicy = "batch";
      nix.daemonIOSchedClass = "idle";

      # A bare `result` symlink in a job workspace is an indirect GC root, so
      # without this every closure CI has ever built stays pinned. Workflows
      # should still use --no-link; this is the backstop.
      systemd.tmpfiles.rules = [
        "e /var/lib/private/forgejo-runner/link/work - - - 3d"
      ];
    };
}

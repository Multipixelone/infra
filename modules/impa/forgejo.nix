{ inputs, ... }:
let
  # Shared by services.forgejo, the firewall opening and the publication route
  # below; the route is resolved at flake level, where the NixOS module's own
  # config is out of scope, so the port cannot be read back from the service.
  webPort = 3000;
  sshPort = 2222;

  # Canonical name for a private application is <name>.<site.internalZone>
  # (lib/service-publication.nix:65). Flipping `public` later would move the
  # canonical to the apps.finnrut.is zone, so ROOT_URL and this binding have to
  # move together.
  domain = "forgejo.nyc.finnrut.is";

  adminSecret = "${inputs.secrets}/forgejo/admin-password.age";
  # Guarded the way modules/service-publication/nixos.nix guards its own
  # secrets: the flake has to keep evaluating on every host before the .age
  # lands in nix-secrets, or a lockfile bump becomes a prerequisite for
  # evaluating unrelated machines.
  hasAdminSecret = builtins.pathExists adminSecret;
in
{
  # Internal only, deliberately. Git-over-HTTPS talks to /<owner>/<repo>.git,
  # /…/git-upload-pack and /…/git-receive-pack — paths that are not a fixed
  # prefix, so no route-level Access bypass can carve them out of a published
  # hostname, and a bypass at / would simply make the forge public. The Actions
  # runner cannot pass an interactive Access login either. LAN and WireGuard
  # clients are inside sites.nyc.trustedClientCidrs and reach it directly
  # through the generated nginx ACL.
  servicePublication.applications.forgejo = {
    site = "nyc";
    homepage = {
      group = "Development";
      description = "Self-hosted Git forge and CI";
      icon = "forgejo";
    };
    # nginx defaults client_max_body_size to 1m and proxy_read_timeout to 60s,
    # which kills `git push` and LFS uploads at 1 MB and times out a large
    # clone. Server level, so it covers every location without touching the
    # generated per-route ACLs.
    nginx.extraConfig = ''
      client_max_body_size 1024M;
      proxy_request_buffering off;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
    '';
    routes.root = {
      backend = {
        host = "impa";
        port = webPort;
      };
      health = {
        # Unauthenticated even with REQUIRE_SIGNIN_VIEW set: 200 with
        # {"status":"pass"}, 503 when a subsystem check fails.
        path = "/api/healthz";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 8;
      };
    };
  };

  configurations.nixos.impa.module =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      age.secrets = lib.mkIf hasAdminSecret {
        "forgejo-admin-password" = {
          file = adminSecret;
          # Consumed through systemd LoadCredential=, which systemd reads as
          # root before dropping to the unit's user, so root ownership is both
          # correct and tighter than handing it to the forgejo user.
          owner = "root";
          group = "root";
          mode = "0400";
        };
      };

      services.forgejo = {
        enable = true;
        # LTS rather than pkgs.forgejo. This box sits unattended in NYC and
        # carries public ingress; the newest minor buys nothing here.
        package = pkgs.forgejo-lts;

        # sqlite3 over postgres deliberately: impa has 8 GiB and no swap while
        # already running blocky, unbound, dnscrypt-proxy, nginx, ACME and
        # cloudflared. A second resident database daemon on the box that
        # resolves DNS for the whole house is the wrong trade for a forge with
        # one human and one runner. It also keeps the whole of Forgejo's state
        # inside a single filesystem snapshot, which is what makes the backup
        # atomic.
        database.type = "sqlite3";
        lfs.enable = true;

        dump = {
          enable = true;
          interval = "Sun 03:00";
          # Uncompressed on purpose: restic dedups and compresses repo-side, so
          # a pre-compressed archive would land as a full-size new blob every
          # week and share no chunks with its predecessor.
          type = "tar";
          age = "2w";
        };

        settings = {
          DEFAULT.APP_NAME = "finnrut forge";

          server = {
            PROTOCOL = "http";
            # Must be loopback. impa is both the proxy and the backend for this
            # route, and lib/service-publication.nix:117 rewrites the generated
            # proxy_pass target to 127.0.0.1 in exactly that case — binding the
            # LAN address instead would 502 every request.
            HTTP_ADDR = "127.0.0.1";
            HTTP_PORT = webPort;
            DOMAIN = domain;
            ROOT_URL = "https://${domain}/";

            # Built-in SSH server rather than a `git` account on the host sshd.
            # The hardened upstream unit sets CapabilityBoundingSet = "", so
            # this process can never bind below 1024 and port 22 was never on
            # the table; and leaving impa's sshd untouched keeps the colmena
            # deploy channel out of the blast radius.
            DISABLE_SSH = false;
            START_SSH_SERVER = true;
            BUILTIN_SSH_SERVER_USER = "git";
            SSH_DOMAIN = domain;
            SSH_LISTEN_HOST = "0.0.0.0";
            SSH_LISTEN_PORT = sshPort;
            SSH_PORT = sshPort;
          };

          session.COOKIE_SECURE = true;

          service = {
            DISABLE_REGISTRATION = true;
            ENABLE_NOTIFY_MAIL = false;
          };
          "service.explore".REQUIRE_SIGNIN_VIEW = true;

          # modules/email/ holds protonmail-bridge and thunderbird, both
          # desktop-tier; there is no SMTP relay impa can reach. Password reset
          # is `forgejo admin user change-password` over SSH.
          mailer.ENABLED = false;

          actions = {
            ENABLED = true;
            # Defaults are 90 and 365 days. This is a 1 TB disk shared with
            # everything else impa does, and the artifacts are reproducible.
            ARTIFACT_RETENTION_DAYS = 7;
            LOG_RETENTION_DAYS = 30;
          };

          # A whole-fleet closure build can legitimately run for hours, and
          # both Forgejo and the runner otherwise cap a job at 3h — which would
          # kill the host-closure matrix at the same wall-clock every time and
          # look like a build failure rather than a timeout.
          "actions.timeout" = {
            DEFAULT = "8h";
            ZOMBIE_TASK = "10m";
            ABANDONED_JOB = "24h";
          };

          "cron.git_gc_repos" = {
            ENABLED = true;
            SCHEDULE = "@every 168h";
            TIMEOUT = "600s";
            # --auto, never --aggressive: an aggressive repack is the single
            # most likely thing on this box to hit MemoryMax below.
            ARGS = "--auto";
          };
          "cron.update_checker".ENABLED = false;

          log.LEVEL = "Info";
        };
      };

      # Git over SSH cannot traverse the Cloudflare tunnel — the route schema
      # only admits http/https and the tunnel emits nothing but HTTP ingress —
      # so this port is the only path to it, and it is LAN/WireGuard only.
      # HTTP is deliberately absent: Forgejo binds loopback and nginx reaches
      # it without leaving the box.
      networking.firewall.allowedTCPPorts = [ sshPort ];

      # impa is 8 GiB with no swap, and it is the house's public ingress and
      # one of two DNS resolvers. A runaway repack has to degrade into a failed
      # push, not a DNS outage. git subprocesses inherit this cgroup, so the
      # bound covers the whole tree rather than just the Go process.
      systemd.services.forgejo = {
        onFailure = [ "notify-telegram@%n.service" ];
        serviceConfig = {
          MemoryAccounting = true;
          MemoryHigh = "1500M";
          MemoryMax = "2G";
          CPUAccounting = true;
          CPUWeight = 50;
          CPUQuota = "400%";
          IOWeight = 50;
          TasksMax = 512;
        };
      };

      systemd.services.forgejo-dump = {
        onFailure = [ "notify-telegram@%n.service" ];
        serviceConfig = {
          MemoryMax = "1G";
          CPUWeight = 20;
          IOWeight = 20;
        };
      };

      # Idempotent: guarded on `admin user list`, so it is a no-op on every
      # activation after the first. `admin user create` has no --password-file,
      # so the value is on argv for the life of that one exec — visible to root
      # and to the forgejo user, and only ever once.
      systemd.services.forgejo-bootstrap = lib.mkIf hasAdminSecret {
        description = "Idempotent Forgejo admin bootstrap";
        wantedBy = [ "multi-user.target" ];
        after = [ "forgejo.service" ];
        requires = [ "forgejo.service" ];
        onFailure = [ "notify-telegram@%n.service" ];
        path = [
          config.services.forgejo.package
          pkgs.curl
        ];
        environment = {
          USER = config.services.forgejo.user;
          HOME = config.services.forgejo.stateDir;
          FORGEJO_WORK_DIR = config.services.forgejo.stateDir;
          FORGEJO_CUSTOM = config.services.forgejo.customDir;
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = config.services.forgejo.user;
          Group = config.services.forgejo.group;
          ProtectProc = "invisible";
          ProcSubset = "pid";
          LoadCredential = [
            "adminpw:${config.age.secrets."forgejo-admin-password".path}"
          ];
        };
        script = ''
          # forgejo.service is Type=notify, but what the admin commands need is
          # the HTTP listener, which comes up later. Poll it rather than racing.
          for _ in $(seq 1 60); do
            curl -sf -o /dev/null http://127.0.0.1:${toString webPort}/api/healthz && break
            sleep 2
          done

          if ! forgejo admin user list --admin | grep -qw tunnel; then
            forgejo admin user create \
              --admin --username tunnel --email me@finnrut.is \
              --must-change-password=false \
              --password "$(cat "$CREDENTIALS_DIRECTORY/adminpw")"
          fi
        '';
      };
    };
}

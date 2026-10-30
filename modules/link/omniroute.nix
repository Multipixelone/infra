{ lib, ... }:
let
  # OmniRoute's default; shared by the firewall and the publication route.
  port = 20128;
in
{
  # Published as ai.nyc.finnrut.is (internal only). OmniRoute binds 0.0.0.0,
  # but service publication narrows the backend port to the proxy hosts, so
  # LAN/VPN clients reach it only through the authenticated-TLS proxy.
  servicePublication.applications.ai = {
    site = "nyc";
    homepage = {
      name = "OmniRoute";
      group = "AI";
      description = "AI model router and provider dashboard";
      icon = "mdi-robot";
    };
    # LLM responses stream over SSE, and non-streaming reasoning calls can sit
    # silent for many minutes; long-context
    # requests carry large bodies (images, files).
    nginx.extraConfig = ''
      client_max_body_size 100M;
      proxy_buffering off;
      proxy_request_buffering off;
      proxy_read_timeout 1800s;
      proxy_send_timeout 1800s;
    '';
    routes.root = {
      backend = {
        host = "link";
        inherit port;
      };
      health = {
        # Unauthenticated liveness endpoint; / answers 307 to the dashboard.
        path = "/api/health";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 8;
      };
    };
  };

  configurations.nixos.link.module =
    { pkgs, ... }:
    let
      # OmniRoute stays an npm-global install (prebuilt ~1 GB Next.js bundle
      # with native deps, no lockfile), so Nix owns only the service and the
      # updater. All configuration lives in ~/.config/omniroute and is managed
      # through the web UI.
      prefix = "/home/tunnel/.npm-global";
      pkgDir = "${prefix}/lib/node_modules/omniroute";
      bin = "${prefix}/bin/omniroute";
      # Pinned major: better-sqlite3 and onnxruntime are native modules built
      # against this node's ABI, and `npm install` on an unchanged version will
      # not rebuild them if nixpkgs moves the default nodejs.
      nodejs = pkgs.nodejs_24;
      npm = "${nodejs}/bin/npm";
      path = lib.makeBinPath [
        nodejs
        pkgs.bash
        pkgs.coreutils
        pkgs.gnugrep
        pkgs.gnused
        pkgs.python3 # node-gyp fallback when a native prebuild is missing
        pkgs.gnumake
        pkgs.gcc
      ];
      environment = [
        "HOME=/home/tunnel"
        "PATH=${prefix}/bin:${path}"
        "NPM_CONFIG_PREFIX=${prefix}"
      ];

      # Serialise every npm run against the shared prefix: the bootstrap, the
      # updater and a Persistent timer firing at boot can otherwise overlap.
      lock = "${pkgs.util-linux}/bin/flock ${prefix}/.omniroute-install.lock";

      installedVersion = ''
        ${lib.getExe pkgs.jq} -r .version "${pkgDir}/package.json" 2>/dev/null || true
      '';

      bootstrap = pkgs.writeShellScript "omniroute-bootstrap" ''
        set -euo pipefail
        ${pkgs.coreutils}/bin/mkdir -p "${prefix}"
        abi_file="${prefix}/.omniroute-node-abi"
        abi="$(${nodejs}/bin/node -p process.versions.modules)"
        if [ ! -x "${bin}" ]; then
          ${lock} ${npm} install -g omniroute@latest
        elif [ "$(cat "$abi_file" 2>/dev/null || true)" != "$abi" ]; then
          # Node major changed under an existing install: rebuild native deps.
          ${lock} ${npm} rebuild -g omniroute
        fi
        echo "$abi" > "$abi_file"
      '';

      healthy = ''
        for _ in $(${pkgs.coreutils}/bin/seq 30); do
          if ${lib.getExe pkgs.curl} -fsS -o /dev/null --max-time 5 \
            http://127.0.0.1:${toString port}/api/health; then
            return 0
          fi
          ${pkgs.coreutils}/bin/sleep 3
        done
        return 1
      '';

      update = pkgs.writeShellScript "omniroute-update" ''
        set -euo pipefail
        systemctl=${pkgs.systemd}/bin/systemctl
        healthy() { ${healthy} }

        before="$(${installedVersion})"
        ${lock} ${npm} install -g omniroute@latest
        after="$(${installedVersion})"
        if [ "$before" = "$after" ]; then
          echo "omniroute already at $after"
          exit 0
        fi

        echo "omniroute updated: ''${before:-none} -> $after"
        if ! $systemctl --user is-active --quiet omniroute.service; then
          exit 0 # stopped on purpose; picks up the new version on next start
        fi
        $systemctl --user restart omniroute.service
        if healthy; then
          exit 0
        fi

        # Installed fine but does not come up: roll back rather than staying
        # down until the next daily run, and fail so it shows in the journal.
        echo "omniroute $after failed its health check" >&2
        if [ -n "$before" ]; then
          echo "rolling back to $before" >&2
          ${lock} ${npm} install -g "omniroute@$before"
          $systemctl --user reset-failed omniroute.service || true
          $systemctl --user restart omniroute.service
        fi
        exit 1
      '';
    in
    {
      # Restricted to the proxy hosts by the service-publication firewall chain.
      networking.firewall.allowedTCPPorts = [ port ];
      # Start at boot, not only at login.
      users.users.tunnel.linger = true;

      home-manager.users.tunnel.systemd.user = {
        services.omniroute = {
          # No After=network-online.target: the user manager has no such
          # unit, and a failed first-run download is retried by Restart.
          Unit.Description = "OmniRoute AI router";
          Service = {
            ExecStartPre = "${bootstrap}";
            # systemd owns restarts, so skip OmniRoute's own crash supervisor.
            ExecStart = "${bin} serve --no-open --no-tray --no-recovery --port ${toString port}";
            # A signal-killed server child makes the CLI parent exit 0, so
            # on-failure would leave it down.
            Restart = "always";
            # Let the CLI forward SIGTERM to its server child before cleanup.
            KillMode = "mixed";
            RestartSec = "5s";
            TimeoutStartSec = "10min"; # first-run bootstrap downloads the bundle
            Environment = environment;
          };
          Install.WantedBy = [ "default.target" ];
        };

        services.omniroute-update = {
          Unit.Description = "Update OmniRoute from npm";
          Service = {
            Type = "oneshot";
            ExecStart = "${update}";
            TimeoutStartSec = "30min";
            Environment = environment;
          };
        };

        timers.omniroute-update = {
          Unit.Description = "Daily OmniRoute update";
          Timer = {
            OnCalendar = "daily";
            Persistent = true;
            RandomizedDelaySec = "1h";
          };
          Install.WantedBy = [ "timers.target" ];
        };
      };
    };
}

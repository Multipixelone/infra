{ inputs, ... }:
{
  caches = [
    {
      url = "https://cache.garnix.io";
      key = "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=";
    }
  ];
  configurations.nixos.link.module =
    { config, pkgs, ... }:
    {
      # Reuse existing secrets already used by productivity modules.
      age.secrets."gcalclient".file = "${inputs.secrets}/gcal/client.age";
      age.secrets."gcalsecret".file = "${inputs.secrets}/gcal/secret.age";
      age.secrets."todoist".file = "${inputs.secrets}/todoist.age";

      home-manager.users.tunnel = {
        home.packages = [
          pkgs.nodejs
          pkgs.gogcli
          (pkgs.writeShellScriptBin "gog-bootstrap-auth" ''
            set -euo pipefail

            tmp="$(mktemp -d)"
            cleanup() { rm -rf "$tmp"; }
            trap cleanup EXIT

            client_id=$(tr -d '\r\n' < ${config.age.secrets."gcalclient".path})
            client_secret=$(tr -d '\r\n' < ${config.age.secrets."gcalsecret".path})

            cat > "$tmp/client_secret.json" <<JSONEOF
            {
              "installed": {
                "client_id": "''${client_id}",
                "client_secret": "''${client_secret}",
                "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                "token_uri": "https://oauth2.googleapis.com/token"
              }
            }
            JSONEOF

            echo "Run: gog auth credentials \"$tmp/client_secret.json\""
            gog auth credentials "$tmp/client_secret.json"
          '')
        ];

        systemd.user.services.openclaw-gateway = {
          Unit = {
            Description = "OpenClaw gateway";
            After = [ "network-online.target" ];
            Wants = [ "network-online.target" ];
          };
          Service = {
            ExecStartPre = ''
              ${pkgs.bash}/bin/bash -lc 'set -euo pipefail; ${pkgs.coreutils}/bin/mkdir -p "$HOME/.openclaw" "$HOME/.npm-global"; if [ ! -x "$HOME/.npm-global/bin/openclaw" ]; then ${pkgs.nodejs}/bin/npm --prefix "$HOME/.npm-global" install -g openclaw; fi'
            '';
            ExecStart = "%h/.npm-global/bin/openclaw gateway --port 18789";
            WorkingDirectory = "%h/.openclaw";
            Restart = "always";
            RestartSec = "5s";
            Environment = [
              "HOME=%h"
              "PATH=%h/.local/bin:%h/.npm-global/bin:%h/.local/share/flatpak/exports/bin:/var/lib/flatpak/exports/bin:%h/.nix-profile/bin:/nix/profile/bin:%h/.local/state/nix/profile/bin:/etc/profiles/per-user/tunnel/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:${pkgs.coreutils}/bin:${pkgs.nodejs}/bin"
              "NPM_CONFIG_PREFIX=%h/.npm-global"
              "OPENCLAW_STATE_DIR=%h/.openclaw"
            ];
          };
          Install.WantedBy = [ "default.target" ];
        };

        # Remote Todoist MCP endpoint (auth handled by MCP client/OAuth flow).
        mcp-servers.settings.servers.todoist = {
          type = "http";
          url = "https://ai.todoist.net/mcp";
        };
      };
    };
}

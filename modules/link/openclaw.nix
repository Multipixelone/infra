{ inputs, rootPath, ... }:
let
  agentmail-scripts = ./agentmail-scripts;
in
{
  caches = [
    {
      url = "https://cache.garnix.io";
      key = "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=";
    }
  ];

  configurations.nixos.link.module =
    {
      config,
      pkgs,
      ...
    }:
    let
      # --- Python environments ------------------------------------------------

      # python3 defaults to 3.14 which has broken pydantic-core. Pin 3.12
      # and scrub PYTHON* env that HA's systemd service leaks.
      agentmail-pkg = pkgs.python312Packages.callPackage "${rootPath}/pkgs/agentmail" { };

      pyEnv = pkgs.python312.withPackages (_ps: [ agentmail-pkg ]);

      pyEnvStdlib = pkgs.python312;

      # --- AgentMail script wrappers ------------------------------------------

      checkInbox = pkgs.writeShellScriptBin "agentmail-check-inbox" ''
        unset PYTHONPATH PYTHONHOME PYTHONNOUSERSITE
        exec ${pyEnv}/bin/python3 ${agentmail-scripts}/check_inbox.py "$@"
      '';

      sendEmail = pkgs.writeShellScriptBin "agentmail-send-email" ''
        unset PYTHONPATH PYTHONHOME PYTHONNOUSERSITE
        exec ${pyEnv}/bin/python3 ${agentmail-scripts}/send_email.py "$@"
      '';

      setupWebhook = pkgs.writeShellScriptBin "agentmail-setup-webhook" ''
        unset PYTHONPATH PYTHONHOME PYTHONNOUSERSITE
        exec ${pyEnv}/bin/python3 ${agentmail-scripts}/setup_webhook.py "$@"
      '';

      # --- AgentMail runners (inject secrets at runtime) ----------------------

      checkInboxRunner = pkgs.writeShellApplication {
        name = "agentmail-check-inbox-runner";
        runtimeInputs = [ checkInbox ];
        text = ''
          AGENTMAIL_API_KEY="$(< "${config.age.secrets."agentmail-api-key".path}")"
          export AGENTMAIL_API_KEY
          exec agentmail-check-inbox "$@"
        '';
      };

      sendEmailRunner = pkgs.writeShellApplication {
        name = "agentmail-send-email-runner";
        runtimeInputs = [ sendEmail ];
        text = ''
          AGENTMAIL_API_KEY="$(< "${config.age.secrets."agentmail-api-key".path}")"
          export AGENTMAIL_API_KEY
          exec agentmail-send-email "$@"
        '';
      };

      setupWebhookRunner = pkgs.writeShellApplication {
        name = "agentmail-setup-webhook-runner";
        runtimeInputs = [ setupWebhook ];
        text = ''
          AGENTMAIL_API_KEY="$(< "${config.age.secrets."agentmail-api-key".path}")"
          export AGENTMAIL_API_KEY
          exec agentmail-setup-webhook "$@"
        '';
      };

      # --- Morning nudge time (stdlib only) ----------------------------------

      nudgeTime = pkgs.writeShellScriptBin "nudge-time" ''
        unset PYTHONPATH PYTHONHOME PYTHONNOUSERSITE
        exec ${pyEnvStdlib}/bin/python3 ${./nudge_time.py} "$@"
      '';

      # --- Notion CLI --------------------------------------------------------

      ntn = pkgs.callPackage "${rootPath}/pkgs/ntn" { };
    in
    {

      # Reuse existing secrets already used by productivity modules.
      age.secrets."gcalclient".file = "${inputs.secrets}/gcal/client.age";
      age.secrets."gcalsecret".file = "${inputs.secrets}/gcal/secret.age";
      age.secrets."todoist".file = "${inputs.secrets}/todoist.age";
      age.secrets."agentmail-api-key" = {
        file = "${inputs.secrets}/ai/agentmail.age";
        owner = "tunnel";
        group = "users";
        mode = "0400";
      };

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

          # AgentMail script runners (with API key injected)
          checkInboxRunner
          sendEmailRunner
          setupWebhookRunner

          # Morning nudge time calculator (stdlib only, no secrets needed)
          nudgeTime

          # Notion CLI — for Kestrel's Obsidian→Notion bridge
          ntn
        ];

        systemd.user.services.openclaw-gateway = {
          Unit = {
            Description = "OpenClaw gateway";
            After = [ "network-online.target" ];
            Wants = [ "network-online.target" ];
          };
          Service = {
            # NOTE: paths are spelled absolutely (not via %h) because
            # `openclaw doctor` reads the raw unit file rather than the
            # runtime-expanded environment, and treats `%h` literally —
            # which makes its service-config and PATH validations fail.
            ExecStartPre = ''
              ${pkgs.bash}/bin/bash -lc 'set -euo pipefail; ${pkgs.coreutils}/bin/mkdir -p "$HOME/.openclaw" "$HOME/.npm-global"; NEED_INSTALL=0; if [ ! -x "$HOME/.npm-global/bin/openclaw" ]; then NEED_INSTALL=1; elif ! "$HOME/.npm-global/bin/openclaw" --version >/dev/null 2>&1; then NEED_INSTALL=1; fi; if [ "$NEED_INSTALL" = "1" ]; then ${pkgs.nodejs}/bin/npm --prefix "$HOME/.npm-global" install -g openclaw; fi'
            '';
            ExecStart = "/home/tunnel/.npm-global/bin/openclaw gateway --port 18789";
            WorkingDirectory = "/home/tunnel/.openclaw";
            Restart = "always";
            RestartSec = "5s";
            Environment = [
              "HOME=/home/tunnel"
              "PATH=/home/tunnel/.local/bin:/home/tunnel/.npm-global/bin:/home/tunnel/bin:/home/tunnel/.local/share/flatpak/exports/bin:/var/lib/flatpak/exports/bin:/home/tunnel/.nix-profile/bin:/nix/profile/bin:/home/tunnel/.local/state/nix/profile/bin:/etc/profiles/per-user/tunnel/bin:/nix/var/nix/profiles/default/bin:/run/current-system/sw/bin:/usr/local/bin:/usr/bin:/bin:${pkgs.coreutils}/bin:${pkgs.nodejs}/bin"
              "NPM_CONFIG_PREFIX=/home/tunnel/.npm-global"
              "OPENCLAW_STATE_DIR=/home/tunnel/.openclaw"
            ];
          };
          Install.WantedBy = [ "default.target" ];
        };

        # Remote Todoist MCP endpoint (auth handled by MCP client/OAuth flow).
        mcp-servers.settings.servers.todoist = {
          type = "http";
          url = "https://ai.todoist.net/mcp";
        };

        # Home Assistant MCP server on iot (modules/iot/ha-mcp.nix). LAN-only;
        # iot's homeAddress is 192.168.8.111 (modules/hosts.nix).
        mcp-servers.settings.servers.ha-mcp = {
          type = "http";
          url = "http://192.168.8.111:8086/mcp";
        };
      };
    };
}

{ inputs, ... }:
{
  caches = [
    {
      url = "https://cache.garnix.io";
      key = "cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=";
    }
  ];
  nixpkgs.overlays = [
    inputs.openclaw.overlays.default
    (_final: prev: {
      openclaw-gateway = prev.openclaw-gateway.overrideAttrs (old: {
        env = (old.env or { }) // {
          OPENCLAW_DISABLE_PLUGIN_REGISTRY_MIGRATION = "1";
          # Temporary workaround for upstream postinstall hangs (e.g. lancedb).
          # May break bundled plugin runtime deps/hotfixes; remove when fixed upstream.
          OPENCLAW_DISABLE_BUNDLED_PLUGIN_POSTINSTALL = "1";
        };
      });
    })
  ];
  flake-file.inputs.openclaw.url = "github:openclaw/nix-openclaw";
  configurations.nixos.link.module =
    { config, pkgs, ... }:
    {
      age.secrets."openclaw" = {
        file = "${inputs.secrets}/ai/openclaw.age";
        owner = "tunnel";
        group = "users";
        mode = "0400";
      };
      age.secrets."providers" = {
        file = "${inputs.secrets}/ai/providers.age";
        owner = "tunnel";
        group = "users";
        mode = "0400";
      };
      age.secrets."telegram".file = "${inputs.secrets}/ai/telegram.age";
      # Reuse existing secrets already used by productivity modules.
      age.secrets."gcalclient".file = "${inputs.secrets}/gcal/client.age";
      age.secrets."gcalsecret".file = "${inputs.secrets}/gcal/secret.age";
      age.secrets."todoist".file = "${inputs.secrets}/todoist.age";

      home-manager.users.tunnel = {
        imports = [ inputs.openclaw.homeManagerModules.openclaw ];

        programs.openclaw = {
          enable = true;
          # Force HM to use the overlaid gateway derivation directly.
          # The default pkgs.openclaw bundle can embed its own gateway build.
          package = pkgs.openclaw-gateway;
          bundledPlugins.gogcli.enable = true;

          config = {
            gateway.mode = "local";
            channels.telegram = {
              tokenFile = config.age.secrets."telegram".path;
              allowFrom = [ 763701512 ];
              groups."*".requireMention = true;
            };
          };

          instances.default = {
            enable = true;
            # plugins = [
            #   { source = "github:openclaw/nix-steipete-tools?dir=tools/summarize"; }
            # ];
          };

          # Note: gogcli plugin itself does not declare requiredEnv in
          # nix-steipete-tools, so gcalclient/gcalsecret are available in this
          # host config but are not auto-consumed by the plugin yet.
        };

        # Bootstrap helper: constructs a Google OAuth client JSON from age secrets
        # and runs gog auth credentials. Temp file only; nothing persists.
        home.packages = [
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

        # Remote Todoist MCP endpoint (auth handled by MCP client/OAuth flow).
        mcp-servers.settings.servers.todoist = {
          type = "http";
          url = "https://ai.todoist.net/mcp";
        };

        systemd.user.services.openclaw-gateway.Service.EnvironmentFile = [
          config.age.secrets."openclaw".path
          config.age.secrets."providers".path
        ];
      };
    };
}

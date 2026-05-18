_: {
  configurations.nixos.iot.module =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    {
      networking.firewall.allowedTCPPorts = [ 8086 ];

      systemd.services.ha-mcp = {
        description = "Home Assistant MCP server";
        after = [
          "network-online.target"
          "home-assistant.service"
        ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];

        # Runs as `hass` so the existing homeassistant-token secret
        # (declared in homeassistant.nix, owner=hass, mode=0400) is readable
        # without touching ownership. Same trust domain as HA itself.
        serviceConfig = {
          User = "hass";
          Group = "hass";
          Restart = "on-failure";
          RestartSec = 5;
          StateDirectory = "ha-mcp";
          WorkingDirectory = "/var/lib/ha-mcp";

          ExecStart = lib.getExe (
            pkgs.writeShellApplication {
              name = "ha-mcp-run";
              runtimeInputs = [ pkgs.ha-mcp ];
              text = ''
                HOMEASSISTANT_TOKEN="$(< "${config.age.secrets."homeassistant-token".path}")"
                export HOMEASSISTANT_TOKEN
                export HOMEASSISTANT_URL="http://127.0.0.1:8123"
                export MCP_PORT=8086
                export MCP_SECRET_PATH="/mcp"
                # ENABLE_YAML_CONFIG_EDITING + HAMCP_ENABLE_FILESYSTEM_TOOLS gate the
                # 5 tools backed by the ha_mcp_tools custom component (installed via
                # services.home-assistant.customComponents).
                export ENABLE_YAML_CONFIG_EDITING=true
                export HAMCP_ENABLE_FILESYSTEM_TOOLS=true
                exec ha-mcp-web
              '';
            }
          );

          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
        };
      };
    };
}

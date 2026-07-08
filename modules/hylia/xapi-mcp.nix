{ config, ... }:
let
  username = config.flake.meta.owner.username;
in
{
  configurations.darwin.hylia.module =
    { pkgs, ... }:
    {
      home-manager.users.${username} = {
        # nodejs provides `npx`, which the xapi-fluso server below shells out to.
        home.packages = [ pkgs.nodejs ];

        # X (Twitter) API via xurl's MCP bridge. hylia-only; shared servers live
        # in modules/shell/ai/shared.nix.
        mcp-servers.settings.servers.xapi-fluso = {
          command = "npx";
          args = [
            "-y"
            "@xdevplatform/xurl"
            "mcp"
            "-u"
            "Flusoai"
            "https://api.x.com/mcp"
          ];
        };
      };
    };
}

{ inputs, ... }:
{
  nixpkgs.config.allowUnfreePackages = [ "claude-code" ];
  flake.modules.homeManager.base =
    { pkgs, ... }:
    {
      programs.claude-code = {
        mcpServers =
          (inputs.mcp-servers-nix.lib.evalModule pkgs {
            programs = {
              playwright.enable = true;
              nixos.enable = true;
              codex.enable = true;
              filesystem = {
                enable = true;
                args = [ ".." ];
              };
            };
          }).config.settings.servers;
        enable = true;
        settings = {
          theme = "dark";
          autoUpdates = false;
          includeCoAuthoredBy = false;
          autoCompactEnabled = false;
          enableAllProjectMcpServers = true;
          outputStyle = "Explanatory";
          model = "claude-opus-4-6";
        };
      };
    };
}

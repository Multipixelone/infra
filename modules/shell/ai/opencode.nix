{
  config,
  ...
}:
{
  flake.modules.homeManager = {
    gui = {
      stylix.targets.opencode.enable = false;
      catppuccin.opencode.enable = false;
    };
    base =
      let
        aiConfig = config.flake.aiConfig;
      in
      {
        programs.opencode = {
          enable = true;
          enableMcpIntegration = true;
          inherit (aiConfig) context;
          agents = aiConfig.agentsDir;
          skills = aiConfig.skillsDir;
          settings = {
            model = "anthropic/claude-sonnet-4-5";
            autoupdate = false;
          };
        };
      };
  };
}

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
          agents = aiConfig.agentsDir;
          skills = aiConfig.skillsDir;
          rules = aiConfig.rulesText;
          settings = {
            model = "anthropic/claude-sonnet-4-5";
            autoupdate = false;
          };
        };
      };
  };
}

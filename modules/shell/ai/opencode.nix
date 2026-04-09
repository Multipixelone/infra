{
  config,
  ...
}:
{
  flake.modules.homeManager.base =
    _:
    let
      aiConfig = config.flake.aiConfig;
    in
    {
      stylix.targets.opencode.enable = false;
      catppuccin.opencode.enable = false;
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
}

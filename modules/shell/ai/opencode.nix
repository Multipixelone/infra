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
            plugin = [ "@ex-machina/opencode-anthropic-auth" ];
            model = "github-copilot/gpt-5.3-codex";
            agent.plan.model = "anthropic/claude-opus-4-7";
            agent.plan.thinking = "high";
            autoupdate = false;
            agent.build.permission.task = {
              "*" = "allow";
            };
            agent.plan.permission.task = {
              "*" = "allow";
            };
          };
        };
      };
  };
}

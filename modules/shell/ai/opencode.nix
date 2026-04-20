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
        omoConfig = builtins.toJSON {
          "$schema" = "https://unpkg.com/oh-my-opencode-slim@latest/oh-my-opencode-slim.schema.json";
          multiplexer = {
            type = "zellij";
          };
          preset = "custom";
          council = {
            master = {
              model = "github-copilot/gpt-5.3-codex";
            };
            presets = {
              default = {
                alpha = {
                  model = "anthropic/claude-opus-4-7";
                };
                beta = {
                  model = "github-copilot/gemini-3.1-pro-preview";
                };
                gamma = {
                  model = "github-copilot/grok-code-fast-1";
                };
              };
            };
          };
          presets = {
            custom = {
              orchestrator = {
                model = "anthropic/claude-opus-4-7";
                variant = "high";
                skills = [ "*" ];
                mcps = [ "*" ];
              };
              oracle = {
                model = "github-copilot/gemini-3.1-pro-preview";
                variant = "high";
                skills = [ "simplify" ];
                mcps = [ ];
              };
              librarian = {
                model = "github-copilot/claude-haiku-4-5";
                variant = "low";
                skills = [ ];
                mcps = [ "*" ];
              };
              explorer = {
                model = "github-copilot/grok-code-fast-1";
                variant = "low";
                skills = [ "cartography" ];
                mcps = [ ];
              };
              designer = {
                model = "github-copilot/gemini-3.1-pro-preview";
                variant = "medium";
                skills = [ ];
                mcps = [ ];
              };
              fixer = {
                model = "github-copilot/gpt-5.3-codex";
                variant = "low";
                skills = [ ];
                mcps = [ ];
              };
              observer = {
                model = "github-copilot/gpt-5.4-mini";
                variant = "low";
                skills = [ ];
                mcps = [ ];
              };
            };
          };
        };
      in
      {
        programs.opencode = {
          enable = true;
          enableMcpIntegration = true;
          inherit (aiConfig) context;
          agents = aiConfig.agentsDir;
          skills = aiConfig.skillsDir;
          settings = {
            plugin = [
              "@ex-machina/opencode-anthropic-auth"
              "oh-my-opencode-slim"
              "true-mem"
            ];
            model = "github-copilot/gpt-5.3-codex";
            autoupdate = false;
            agent.build.permission.task = {
              "*" = "allow";
            };
            agent.plan.permission.task = {
              "*" = "allow";
            };
          };
        };

        xdg.configFile."opencode/oh-my-opencode-slim.json".text = omoConfig;
      };
  };
}

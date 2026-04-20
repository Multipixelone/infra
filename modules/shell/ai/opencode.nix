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
      {
        pkgs,
        lib,
        ...
      }:
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
          lsp = {
            nixd = {
              command = [
                (lib.getExe pkgs.nixd)
                "--inlay-hints=true"
              ];
              extensions = [ ".nix" ];
            };
            basedpyright = {
              command = [
                "${pkgs.basedpyright}/bin/basedpyright-langserver"
                "--stdio"
              ];
              extensions = [
                ".py"
                ".pyi"
              ];
            };
            ruff = {
              command = [
                (lib.getExe pkgs.ruff)
                "server"
              ];
              extensions = [
                ".py"
                ".pyi"
              ];
            };
            "typescript-language-server" = {
              command = [
                (lib.getExe pkgs.typescript-language-server)
                "--stdio"
              ];
              extensions = [
                ".ts"
                ".tsx"
                ".js"
                ".jsx"
                ".mjs"
                ".cjs"
              ];
            };
            "vscode-css-language-server" = {
              command = [
                "${pkgs.vscode-langservers-extracted}/bin/vscode-css-language-server"
                "--stdio"
              ];
              extensions = [
                ".css"
                ".scss"
                ".less"
              ];
            };
            "vscode-html-language-server" = {
              command = [
                "${pkgs.vscode-langservers-extracted}/bin/vscode-html-language-server"
                "--stdio"
              ];
              extensions = [
                ".html"
                ".htm"
              ];
            };
            "vscode-json-language-server" = {
              command = [
                "${pkgs.vscode-langservers-extracted}/bin/vscode-json-language-server"
                "--stdio"
              ];
              extensions = [
                ".json"
                ".jsonc"
              ];
            };
            yaml = {
              command = [
                "${pkgs.yaml-language-server}/bin/yaml-language-server"
                "--stdio"
              ];
              extensions = [
                ".yaml"
                ".yml"
              ];
            };
            taplo = {
              command = [
                (lib.getExe pkgs.taplo)
                "lsp"
                "stdio"
              ];
              extensions = [ ".toml" ];
            };
            marksman = {
              command = [
                (lib.getExe pkgs.marksman)
                "server"
              ];
              extensions = [
                ".md"
                ".markdown"
              ];
            };
            texlab = {
              command = [ (lib.getExe pkgs.texlab) ];
              extensions = [
                ".tex"
                ".bib"
              ];
            };
            tinymist = {
              command = [ (lib.getExe pkgs.tinymist) ];
              extensions = [ ".typ" ];
            };
            "astro-ls" = {
              command = [
                "${pkgs.astro-language-server}/bin/astro-ls"
                "--stdio"
              ];
              extensions = [ ".astro" ];
            };
            "fish-lsp" = {
              command = [
                (lib.getExe pkgs.fish-lsp)
                "start"
              ];
              extensions = [ ".fish" ];
            };
          };
          presets = {
            custom = {
              orchestrator = {
                model = "anthropic/claude-opus-4-7";
                variant = "high";
                skills = [ "*" ];
                mcps = [
                  "*"
                  "websearch"
                ];
              };
              oracle = {
                model = "github-copilot/gemini-3.1-pro-preview";
                variant = "high";
                skills = [ ];
                mcps = [ ];
              };
              librarian = {
                model = "github-copilot/claude-haiku-4.5";
                # haiku doesn't support reasoning effort
                # variant = "low";
                skills = [ ];
                mcps = [
                  "websearch"
                  "context7"
                  "grep_app"
                ];
              };
              explorer = {
                model = "github-copilot/grok-code-fast-1";
                variant = "low";
                skills = [ ];
                mcps = [ ];
              };
              designer = {
                model = "github-copilot/gemini-3.1-pro-preview";
                variant = "medium";
                skills = [ "agent-browser" ];
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
              "@simonwjackson/opencode-direnv"
              "oh-my-opencode-slim"
              "true-mem"
              "openrtk"
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

        programs.fish.shellAliases.oc = "opencode";
        programs.fish.functions.ocd = ''
          # Always run opencode from the repo root so relative paths in
          # config work (e.g. {file:./secrets/github-mcp-pat}).
          set -l root (git rev-parse --show-toplevel 2>/dev/null; or echo $PWD)
          cd $root; or return
          opencode $argv
        '';

        xdg.configFile."opencode/oh-my-opencode-slim.json".text = omoConfig;
      };
  };
}

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

        # ── Composable building blocks ──────────────────────────────────
        #
        # Models: reusable model identifiers keyed by short name.
        # Roles:  per-role skills/mcps (model-agnostic).
        # mkPreset: merges a model assignment onto the matching role config.

        models = {
          # anthropic
          claude-opus = "anthropic/claude-opus-4-6";
          claude-opus-next = "anthropic/claude-opus-4-7";
          claude-sonnet = "anthropic/claude-sonnet-4-6";
          claude-haiku = "anthropic/claude-haiku-4-5";
          # copilot
          gemini-pro = "github-copilot/gemini-3.1-pro-preview";
          claude-haiku-copilot = "github-copilot/claude-haiku-4.5";
          grok-fast = "github-copilot/grok-code-fast-1";
          gpt-codex = "github-copilot/gpt-5.3-codex";
          gpt-mini = "github-copilot/gpt-5.4-mini";
          gpt-5-2 = "github-copilot/gpt-5.2";
          # opencode go
          kimi = "opencode-go/kimi-k2.6";
          glm = "opencode-go/glm-5.1";
          mimo-pro = "opencode-go/mimo-v2.5-pro";
          mimo-omni = "opencode-go/mimo-v2-omni";
          minimax = "opencode-go/minimax-m2.7";
          qwen = "opencode-go/qwen3.6-plus";
        };

        # Role definitions: skills, mcps, and optional variant per role.
        # These are model-agnostic — a preset just picks which model fills
        # each role.
        roles = {
          orchestrator = {
            variant = "medium";
            skills = [ "*" ];
            # Keep context7/grep_app off orchestrator so it delegates
            # doc/code lookups to librarian instead of doing them itself.
            mcps = [
              "*"
              "!context7"
              "!grep_app"
            ];
          };
          oracle = {
            variant = "high";
            skills = [ "simplify" ];
            mcps = [ ];
          };
          librarian = {
            # haiku doesn't support reasoning effort — omit variant
            skills = [ ];
            mcps = [
              "websearch"
              "context7"
              "grep_app"
            ];
          };
          explorer = {
            variant = "low";
            skills = [ "cartography" ];
            mcps = [ ];
          };
          designer = {
            variant = "high";
            skills = [ "agent-browser" ];
            mcps = [ ];
          };
          fixer = {
            variant = "medium";
            skills = [ ];
            mcps = [ ];
          };
          observer = {
            variant = "low";
            skills = [ ];
            mcps = [ ];
          };
        };

        # mkPreset :: { role = modelKey; ... } -> preset attrset
        # Merges each role's config with `{ model = models.${modelKey}; }`.
        mkPreset =
          assignments:
          builtins.mapAttrs (
            role: modelKey: { model = models.${modelKey}; } // (roles.${role} or { })
          ) assignments;

        # ── Preset definitions ──────────────────────────────────────────

        # NOTE: kimi is used more then normal here because of 3x limits right now, switch off when no longer so high
        # Anthropic & Opencode-Go only (for when copilot limit is hit)
        specialistsCustom = {
          oracle = "claude-opus-next";
          librarian = "kimi";
          explorer = "kimi";
          designer = "claude-sonnet";
          fixer = "mimo-pro";
          observer = "mimo-omni";
        };

        # Copilot-mixed specialist assignment (default preset).
        specialistsCopilot = {
          oracle = "claude-opus-next";
          librarian = "kimi";
          explorer = "kimi"; # or grok-fast
          designer = "gemini-pro";
          fixer = "mimo-pro";
          observer = "gpt-mini";
        };

        presetCustom = mkPreset (specialistsCustom // { orchestrator = "claude-opus"; });
        presetCopilot = mkPreset (specialistsCopilot // { orchestrator = "gpt-codex"; });

        # ── Shared config sections ──────────────────────────────────────

        councilConfig = {
          master.model = models.kimi; # was: models.gpt-codex
          master_fallback = [
            models.claude-opus-next
            models.qwen # was: models.gemini-pro
          ];
          presets.default = {
            alpha.model = models.claude-opus-next;
            beta.model = models.qwen; # was: models.gemini-pro
            gamma.model = models.kimi;
          };
        };

        fallbackConfig = {
          enabled = true;
          timeoutMs = 15000;
          chains = {
            orchestrator = [
              models.gpt-codex
              models.gpt-5-2
              models.claude-opus-next
            ];
            oracle = [
              models.claude-opus-next
              models.kimi
              models.glm
            ];
            librarian = [
              models.kimi
              models.qwen
              models.claude-haiku
            ];
            explorer = [
              models.kimi
              models.qwen
              models.glm
            ];
            designer = [
              models.gemini-pro
              models.claude-opus-next
              models.glm
            ];
            fixer = [
              models.mimo-pro
              models.kimi
              models.glm
            ];
          };
        };

        lspServers = {
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

        # ── Final assembled config ──────────────────────────────────────

        omoConfig = builtins.toJSON {
          "$schema" = "https://unpkg.com/oh-my-opencode-slim@latest/oh-my-opencode-slim.schema.json";
          multiplexer.type = "zellij";
          preset = "custom";
          council = councilConfig;
          fallback = fallbackConfig;
          todoContinuation = {
            autoEnable = true;
            autoEnableThreshold = 4;
            maxContinuations = 5;
          };
          # Enable observer agent (disabled by default upstream).
          # gpt-5.4-mini is vision-capable, so the block below activates.
          disabled_agents = [ ];
          lsp = lspServers;
          presets = {
            custom = presetCustom;
            copilot = presetCopilot;
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
              "oh-my-opencode-slim@1.0.1"
              # "true-mem"
              "openrtk"
            ];
            # model = "github-copilot/gpt-5.3-codex";
            model = "opencode-go/kimi-k2.6";
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

          # Pick a free port so the oh-my-opencode-slim multiplexer (zellij)
          # can reach opencode's HTTP API. Starting at 4096 and scanning
          # upward lets multiple concurrent / forgotten opencode instances
          # coexist without port conflicts.
          set -l port
          for candidate in (seq 4096 4196)
            if test (ss -Htln "sport = :$candidate" 2>/dev/null | count) -eq 0
              set port $candidate
              break
            end
          end
          if test -z "$port"
            echo "ocd: no free port in 4096-4196" >&2
            return 1
          end

          opencode --port $port $argv
        '';

        xdg.configFile."opencode/oh-my-opencode-slim.json".text = omoConfig;
      };
  };
}

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
          # copilot
          gemini-pro = "github-copilot/gemini-3.1-pro-preview";
          claude-haiku-copilot = "github-copilot/claude-haiku-4.5";
          claude-sonnet-copilot = "github-copilot/claude-sonnet-4.6";
          claude-opus-copilot = "github-copilot/claude-opus-4.5";
          grok-fast = "github-copilot/grok-code-fast-1";
          gpt-codex = "github-copilot/gpt-5.3-codex";
          gpt-5-4 = "github-copilot/gpt-5.4";
          gpt-mini = "github-copilot/gpt-5.4-mini";
          gpt-5-2 = "github-copilot/gpt-5.2";
          # opencode free
          gpt-5-nano = "opencode/gpt-5-nano";
          hy3-preview-free = "opencode/hy3-preview-free";
          ling-26-flash-free = "opencode/ling-2.6-flash-free";
          minimax-m25-free = "opencode/minimax-m2.5-free";
          nemotron-3-super-free = "opencode/nemotron-3-super-free";
          big-pickle = "opencode/big-pickle";
          # opencode go
          kimi = "opencode-go/kimi-k2.6";
          deepseek-pro = "opencode-go/deepseek-v4-pro";
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
            variant = "xhigh";
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

        # Copilot + Opencode-Go only (alternate profile)
        specialistsCustom = {
          oracle = "gpt-5-4";
          librarian = "kimi";
          explorer = "kimi";
          designer = "gemini-pro";
          fixer = "mimo-pro";
          observer = "mimo-omni";
        };

        # opencode-go only (if I hit Copilot limits)
        specialistsGo = {
          oracle = "deepseek-pro";
          librarian = "kimi";
          explorer = "kimi";
          designer = "mimo-pro";
          fixer = "mimo-pro";
          observer = "mimo-omni";
        };

        # Copilot + Opencode-Go specialist assignment (default preset).
        specialistsCopilot = {
          oracle = "gpt-5-4";
          designer = "gemini-pro";
          fixer = "mimo-pro";
          librarian = "ling-26-flash-free";
          explorer = "hy3-preview-free";
          observer = "mimo-omni";
        };

        presetCustom = mkPreset (specialistsCustom // { orchestrator = "gpt-5-4"; });
        presetGo = mkPreset (specialistsGo // { orchestrator = "glm"; });
        presetCopilot = mkPreset (specialistsCopilot // { orchestrator = "gpt-codex"; });

        # ── Shared config sections ──────────────────────────────────────

        councilConfig = {
          master.model = models.gpt-codex;
          master_fallback = [
            models.gpt-codex
            models.gemini-pro
            models.qwen
          ];
          presets.default = {
            alpha.model = models.gemini-pro;
            beta.model = models.claude-sonnet-copilot;
            gamma.model = models.glm;
          };
        };

        fallbackConfig = {
          enabled = true;
          timeoutMs = 15000;
          chains = {
            orchestrator = [
              models.gpt-codex
              models.big-pickle
              models.gpt-5-4
              models.gpt-5-2
              models.kimi
            ];
            oracle = [
              models.claude-sonnet-copilot
              models.gpt-5-4
              models.deepseek-pro
              models.kimi
              models.glm
            ];
            librarian = [
              models.kimi
              models.qwen
              models.grok-fast
              models.claude-haiku-copilot
            ];
            explorer = [
              models.kimi
              models.qwen
              models.glm
            ];
            designer = [
              models.gemini-pro
              models.claude-sonnet-copilot
              models.mimo-pro
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

        # ── Dynamic context pruning ─────────────────────────────────────
        #
        # Tuned for Copilot's request-based billing: cache invalidation is
        # free, so we compress aggressively. Per-model overrides bump the
        # threshold for opencode-go models with windows >128k.
        dcpConfig = builtins.toJSON {
          "$schema" =
            "https://raw.githubusercontent.com/Opencode-DCP/opencode-dynamic-context-pruning/master/dcp.schema.json";
          enabled = true;
          pruneNotification = "detailed";
          pruneNotificationType = "chat";
          experimental = {
            allowSubAgents = false;
            customPrompts = false;
          };
          compress = {
            mode = "range";
            permission = "allow";
            showCompression = false;
            summaryBuffer = true;
            # 128k Copilot cap minus headroom for system prompt + next reply.
            maxContextLimit = 96000;
            minContextLimit = 48000;
            # Only opencode-go models with documented 256k windows.
            # grok-fast is Copilot-routed, so the Copilot cap dominates.
            modelMaxLimits = {
              ${models.kimi} = 192000;
              ${models.minimax} = 192000;
              ${models.qwen} = 192000;
            };
            modelMinLimits = {
              ${models.kimi} = 96000;
              ${models.minimax} = 96000;
              ${models.qwen} = 96000;
            };
            # Free cache invalidation on Copilot — compress earlier and harder.
            nudgeFrequency = 3;
            iterationNudgeThreshold = 15;
            nudgeForce = "strong";
            protectedTools = [
              "task"
              "skill"
              "todowrite"
              "todoread"
            ];
            protectUserMessages = false;
          };
          strategies = {
            deduplication.enabled = true;
            purgeErrors = {
              enabled = true;
              turns = 4;
            };
          };
        };

        # ── Final assembled config ──────────────────────────────────────

        omoConfig = builtins.toJSON {
          "$schema" = "https://unpkg.com/oh-my-opencode-slim@latest/oh-my-opencode-slim.schema.json";
          multiplexer.type = "zellij";
          preset = "copilot";
          websearch.provider = "tavily";
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
            go = presetGo;
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
              "@simonwjackson/opencode-direnv"
              "@tarquinen/opencode-dcp"
              "oh-my-opencode-slim"
              # "true-mem"
              "opencode-history-search"
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
            agent.orchestrator.permission.glob = "deny";
          };
          tui = {
            scroll_speed = 1;
            scroll_acceleration.enabled = true;
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
        xdg.configFile."opencode/dcp.json".text = dcpConfig;
      };
  };
}

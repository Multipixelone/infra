{
  config,
  inputs,
  ...
}:
{
  # Track upstream opencode directly — nixpkgs lags multiple point
  # releases behind, and the JSON→SQLite migration banner bug
  # (anomalyco/opencode#16885) is fixed only on dev.
  flake-file.inputs.opencode = {
    url = "github:anomalyco/opencode";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  flake.modules.homeManager = {
    gui = {
      stylix.targets.opencode.enable = false;
      catppuccin.opencode.enable = false;
    };
    base =
      hmArgs@{
        pkgs,
        lib,
        ...
      }:
      let
        aiConfig = config.flake.aiConfig;

        upstreamOpencode = inputs.opencode.packages.${pkgs.stdenv.hostPlatform.system}.default;
        # opencode's root package.json requires bun@1.3.14, but nixpkgs ships
        # 1.3.13 and the node_modules are built for 1.3.13. Downgrade the
        # packageManager version in package.json so bun's semver check passes.
        # Drop once nixpkgs ships bun ≥ 1.3.14.
        opencodePkg = upstreamOpencode.overrideAttrs (_old: {
          postConfigure = ''
            sed -i 's/"packageManager": "bun@1.3.14"/"packageManager": "bun@1.3.13"/' package.json
          '';
        });

        # ── Composable building blocks ──────────────────────────────────
        #
        # Models: reusable model identifiers keyed by short name.
        # Roles:  per-role skills/mcps (model-agnostic).
        # mkPreset: merges a model and optional variant onto the matching role.

        models = {
          # OpenAI Codex via ChatGPT OAuth. Spark has a separate Pro quota and
          # is deliberately the high-volume worker; its 128k, text-only window
          # makes it a poor orchestrator or observer despite its speed.
          sol = "openai/gpt-5.6-sol";
          terra = "openai/gpt-5.6-terra";
          spark = "openai/gpt-5.3-codex-spark";

          # opencode go
          luna = "opencode-go/gpt-5.6-luna";
          kimi = "opencode-go/kimi-k3";
          deepseek-flash = "opencode-go/deepseek-v4-flash";
          glm = "opencode-go/glm-5.2";
          mimo = "opencode-go/mimo-v2.5";
          mimo-pro = "opencode-go/mimo-v2.5-pro";
          qwen = "opencode-go/qwen3.8-max";
        };

        # Role definitions are model-agnostic. Reasoning variants live in the
        # preset assignment so Go-primary roles do not inherit Codex-only modes.
        roles = {
          orchestrator = {
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
            skills = [ "simplify" ];
            mcps = [ ];
          };
          librarian = {
            skills = [ ];
            mcps = [
              "websearch"
              "context7"
              "grep_app"
            ];
          };
          explorer = {
            skills = [ "cartography" ];
            mcps = [ ];
          };
          designer = {
            skills = [ "agent-browser" ];
            mcps = [ ];
          };
          fixer = {
            skills = [ ];
            mcps = [ ];
          };
          observer = {
            skills = [ ];
            mcps = [ ];
          };
          # Council agent synthesizes councillor outputs directly (no
          # separate council-master since oh-my-opencode-slim 2026-04).
          council = {
            skills = [ ];
            mcps = [ ];
          };
        };

        # mkPreset :: { role = { model = modelKey; variant = ...; }; ... }
        mkPreset =
          assignments:
          builtins.mapAttrs (
            role: assignment:
            {
              model = models.${assignment.model};
            }
            // (removeAttrs assignment [ "model" ])
            // (roles.${role} or { })
          ) assignments;

        # Keep the provider-specific reasoning variant attached to every model
        # when oh-my-opencode-slim advances through a fallback chain.
        modelVariant = variant: id: { inherit id variant; };

        # ── Preset definitions ──────────────────────────────────────────

        # Terra handles the interactive coordinator and implementation lanes,
        # Sol remains the deep-reasoning oracle, and Spark handles bounded
        # lookup work. Go supplies model diversity and quota-independent
        # fallbacks.
        presetGoCodex = mkPreset {
          orchestrator = {
            model = "sol";
            variant = "high";
          };
          oracle = {
            model = "sol";
            variant = "xhigh";
          };
          librarian = {
            model = "spark";
            variant = "low";
          };
          explorer = {
            model = "spark";
            variant = "low";
          };
          designer = {
            model = "terra";
            variant = "medium";
          };
          fixer = {
            model = "terra";
            variant = "high";
          };
          observer.model = "mimo";
          # Council has no per-agent fallback slot. Kimi K3 is retained as the
          # strongest Go synthesizer with reliable stream behavior.
          council = {
            model = "kimi";
            variant = "max";
          };
        };

        # ── Shared config sections ──────────────────────────────────────

        # oh-my-opencode-slim ≥ 2026-04 removed the separate council-master
        # agent; the Council agent now synthesizes councillor outputs
        # directly. `master`/`master_fallback` are deprecated/ignored — the
        # synthesizer model is set via a `council` agent entry in the active
        # preset.
        # Renamed: `councillors_timeout` → `timeout`. New: `councillor_execution_mode`,
        # `councillor_retries`.
        councilConfig = {
          default_preset = "default";
          # 180s was too tight — transient gateway flakiness on
          # opencode-go left beta/gamma re-streaming silently until the
          # wall clock expired. 300s gives councillors room to recover.
          timeout = 300000;
          councillor_execution_mode = "parallel";
          councillor_retries = 3;
          # Keep deliberation on the strongest Go models from three different
          # families; retries contain the impact of an intermittent Qwen Max
          # stream.
          presets.default = {
            alpha = {
              model = models.glm;
              variant = "max";
            };
            beta = {
              model = models.qwen;
              variant = "max";
            };
            gamma = {
              model = models.kimi;
              variant = "max";
            };
          };
        };

        fallbackConfig = {
          enabled = true;
          timeoutMs = 15000;
        };

        agentFallbacks = {
          orchestrator = {
            model = [
              (modelVariant "xhigh" models.sol)
              (modelVariant "xhigh" models.terra)
              (modelVariant "xhigh" models.luna)
              (modelVariant "xhigh" models.spark)
            ];
          };
          oracle = {
            model = [
              (modelVariant "xhigh" models.sol)
              (modelVariant "xhigh" models.luna)
              (modelVariant "xhigh" models.spark)
            ];
          };
          librarian = {
            model = [
              (modelVariant "low" models.spark)
              (modelVariant "low" models.luna)
              (modelVariant "low" models.deepseek-flash)
            ];
          };
          explorer = {
            model = [
              (modelVariant "low" models.spark)
              (modelVariant "low" models.luna)
              (modelVariant "low" models.deepseek-flash)
            ];
          };
          designer = {
            model = [
              (modelVariant "medium" models.terra)
              (modelVariant "max" models.kimi)
              (modelVariant "medium" models.sol)
              (modelVariant "max" models.glm)
              (modelVariant "max" models.qwen)
            ];
          };
          fixer = {
            model = [
              (modelVariant "high" models.terra)
              (modelVariant "high" models.spark)
              (modelVariant "high" models.sol)
              (modelVariant "high" models.luna)
            ];
          };
          # Spark is text-only. Keep the complete observer chain multimodal.
          observer = {
            model = [
              models.mimo
              models.mimo-pro
              models.kimi
              models.sol
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
        # Compaction throws away warm prompt context and consumes quota on the
        # next request. Rare and large beats frequent and small, so nudges stay
        # soft and per-model floors stay high while ceilings guard overflow.
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
            # Conservative fallback for models without an explicit override.
            maxContextLimit = 96000;
            minContextLimit = 64000;
            # Sol and Terra have 1.05M context windows (922k input + 128k
            # output), while Spark has 128k total. Prune around 75% and
            # compress to roughly 45% for Sol/Terra; Spark needs more
            # headroom, so compresses to 31%. Go models remain 256k-class.
            modelMaxLimits = {
              ${models.sol} = 780000;
              ${models.terra} = 780000;
              ${models.spark} = 80000;
              ${models.luna} = 192000;
              ${models.kimi} = 192000;
              ${models.deepseek-flash} = 192000;
              ${models.glm} = 192000;
              ${models.qwen} = 192000;
              ${models.mimo} = 192000;
              ${models.mimo-pro} = 192000;
            };
            modelMinLimits = {
              ${models.sol} = 470000;
              ${models.terra} = 470000;
              ${models.spark} = 40000;
              ${models.luna} = 128000;
              ${models.kimi} = 128000;
              ${models.deepseek-flash} = 128000;
              ${models.glm} = 128000;
              ${models.qwen} = 128000;
              ${models.mimo} = 128000;
              ${models.mimo-pro} = 128000;
            };
            # nudgeFrequency counts fetches between nudges above the ceiling,
            # so higher = quieter. nudgeForce "soft" (the upstream default)
            # makes post-user-message compression less likely than "strong".
            nudgeFrequency = 6;
            iterationNudgeThreshold = 16;
            nudgeForce = "soft";
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
          preset = "go-codex";
          council = councilConfig;
          fallback = fallbackConfig;
          agents = agentFallbacks;
          todoContinuation = {
            autoEnable = true;
            autoEnableThreshold = 4;
            maxContinuations = 5;
          };
          # Enable observer agent (disabled by default upstream).
          # mimo-v2.5 is vision-capable, so the block below activates.
          disabled_agents = [ ];
          lsp = lspServers;
          presets.go-codex = presetGoCodex;
        };
      in
      {

        programs.fish.interactiveShellInit = lib.concatStringsSep "\n\n" [
          # fish
          ''
            set -Ux OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS true
          ''
          # fish
          ''
            # The hosted Parallel Search MCP expands PARALLEL_API_KEY from the
            # process environment. Export it session-wide so every opencode launch
            # inherits it (oc, ocd, bare `opencode`), not just ones wrapped by `ocd`.
            # `set -gx`, never `-Ux`: universal variables persist to
            # fish_variables on disk — don't leak the secret there.
            set -l parallel_env ${hmArgs.config.age.secrets.tavily.path}
            if test -r $parallel_env
              set -l key (string match -rg '^PARALLEL_API_KEY=(.+)$' < $parallel_env)
              test -n "$key"; and set -gx PARALLEL_API_KEY $key
            end
          ''
        ];
        programs.opencode = {
          enable = true;
          package = opencodePkg;
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
            # Ignore any other configured credentials and keep all routing on
            # the two subscription providers represented in the active preset.
            enabled_providers = [
              "openai"
              "opencode-go"
            ];
            provider.openai.models = {
              "gpt-5.6-sol".limit = {
                context = 1050000;
                input = 922000;
                output = 128000;
              };
              "gpt-5.6-terra".limit = {
                context = 1050000;
                input = 922000;
                output = 128000;
              };
              # OpenCode's models.dev catalog exposes Spark as 128k for each
              # required limit field.
              "gpt-5.3-codex-spark".limit = {
                context = 128000;
                input = 128000;
                output = 128000;
              };
            };
            model = models.sol;
            small_model = models.luna;
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

          # Forward the agenix env-file via `env` so external MCP credentials
          # are available to this opencode process.
          set -l envfile ${hmArgs.config.age.secrets.tavily.path}

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

          # `command env` bypasses fish-grc's auto-alias on `env`, which
          # would otherwise wrap opencode's stdout in a line-based
          # colorizer and shred the TUI.
          command env (test -r $envfile; and string match -rv '^#|^$' < $envfile) \
            opencode --port $port $argv
        '';

        xdg.configFile."opencode/oh-my-opencode-slim.json".text = omoConfig;
        xdg.configFile."opencode/dcp.json".text = dcpConfig;
      };
  };
}

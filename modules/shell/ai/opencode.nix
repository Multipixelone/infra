{ config, ... }:
{
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
        # OpenCode fetches this npm plugin; update this version and its schema
        # together here, not with the installer (which writes HM-managed files).
        omoVersion = "3.0.6";

        # ── Composable building blocks ──────────────────────────────────
        #
        # Models: reusable model identifiers keyed by short name.
        # Roles:  per-role skills/mcps (model-agnostic).
        # mkPreset: merges a model and optional variant onto the matching role.

        models = {
          # Combo names are sent verbatim; OmniRoute owns their upstream
          # model selection, reasoning effort, and fallback policy.
          kestral = "omniroute/Kestral";
          subagent = "omniroute/Subagent";
          fixer = "omniroute/Fixer";
          high-effort = "omniroute/High Effort";
        };

        # Role definitions are model-agnostic. Reasoning variants live in the
        # preset assignment.
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
            skills = [ "agent-run-long" ];
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

        # ── Preset definitions ──────────────────────────────────────────

        presetOmniroute = mkPreset {
          orchestrator.model = "kestral";
          oracle.model = "high-effort";
          librarian.model = "subagent";
          explorer.model = "subagent";
          designer.model = "high-effort";
          fixer.model = "fixer";
          observer.model = "kestral";
          council.model = "high-effort";
        };

        # ── Shared config sections ──────────────────────────────────────

        # oh-my-opencode-slim ≥ 2026-04 removed the separate council-master
        # agent; the Council agent now synthesizes councillor outputs
        # directly. `master`/`master_fallback` are deprecated/ignored — the
        # synthesizer model is set via a `council` agent entry in the active
        # preset.
        councilConfig = {
          default_preset = "default";
          # Use distinct routing lanes for the three councillors.
          presets.default = {
            alpha.model = models.high-effort;
            beta.model = models.fixer;
            gamma.model = models.kestral;
          };
        };

        # Each combo already retries and falls back inside OmniRoute.
        fallbackConfig.enabled = false;

        agentFallbacks.fixer.orchestratorPrompt = ''
          @fixer: delegate each independent long-running build, test, or CI validation lane to a separate background fixer. Use non-overlapping scopes; serialize overlaps. On Linux, use the `agent-run-long` skill and helper rather than constructing logging or timing wrappers. Return its compact report fields.
        '';

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
          # Manual mode splits DCP in two: the deterministic cleanup below
          # (deduplication, purgeErrors) keeps running automatically, while
          # compression only happens when asked for via /dcp-compress.
          #
          # It stays off. It was on to stop DCP compressing every couple of
          # minutes, but that was never DCP's judgement — the config was
          # landing in dcp.json while DCP read a stub dcp.jsonc, so every
          # model ran on the stock 50k/100k thresholds and got nudged from
          # 50k of a 1.05M window onward. With the file at the path DCP
          # actually reads, the per-model floors below apply and nudging only
          # starts near the real ceiling, which is when compression is worth
          # its cost.
          #
          # This is only a *default*: DCP persists a per-session manualMode
          # boolean in ~/.local/share/opencode/storage/plugin/dcp/<session>.json
          # and `persisted ?? default` means an existing session keeps whatever
          # it was created with. Flipping this option leaves every already-open
          # session on the old behaviour; patch the key in those state files
          # (it is re-read every request) or start a new session.
          manualMode = {
            enabled = false;
            automaticStrategies = true;
          };
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
            # These are nudge thresholds, not compression targets. Below
            # modelMinLimits DCP stays silent; at or above it turn/iteration
            # reminders switch on; above modelMaxLimits it nudges hard every
            # nudgeFrequency fetches. So the min is where compression pressure
            # *starts* — keep it high or the session compresses all session.
            # Combos can route to models with different context windows.
            # Use the conservative shared thresholds above instead of the
            # old Codex-specific million-token overrides.
            # nudgeFrequency counts fetches between nudges above the ceiling,
            # so higher = quieter. iterationNudgeThreshold is how many messages
            # after a user message before reminders resume, so higher is also
            # quieter. nudgeForce "soft" (the upstream default) makes
            # post-user-message compression less likely than "strong".
            nudgeFrequency = 10;
            iterationNudgeThreshold = 40;
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
          "$schema" = "https://unpkg.com/oh-my-opencode-slim@${omoVersion}/oh-my-opencode-slim.schema.json";
          autoUpdate = false;
          multiplexer.type = "zellij";
          preset = "omniroute";
          council = councilConfig;
          fallback = fallbackConfig;
          agents = agentFallbacks;
          # v3 lacks todoContinuation's prior threshold/cap controls; configure
          # backgroundJobs.orchestratorWake only after verifying its v3 schema.
          # Enable observer agent (disabled by default upstream).
          disabled_agents = [ ];
          presets.omniroute.agents = presetOmniroute;
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
            set -l parallel_env ${hmArgs.config.age.secrets.parallel.path}
            if test -r $parallel_env
              set -l key (string match -rg '^PARALLEL_API_KEY=(.+)$' < $parallel_env)
              test -n "$key"; and set -gx PARALLEL_API_KEY $key
            end
          ''
        ];
        programs.opencode = {
          enable = true;
          package = pkgs.opencode;
          enableMcpIntegration = true;
          inherit (aiConfig) context;
          agents = aiConfig.agentsDir;
          skills = aiConfig.skillsDir;
          settings = {
            # programs.mcp uses Claude-style ${VAR} placeholders, but OpenCode
            # only expands {env:VAR}. OpenCode settings replace the whole
            # server entry imported by enableMcpIntegration rather than
            # merging into it, so restate type/url here -- a headers-only
            # entry fails OpenCode's mcp schema ("mcp.websearch.enabled
            # missing key").
            mcp.websearch = {
              type = "remote";
              url = "https://search.parallel.ai/mcp";
              enabled = true;
              headers.Authorization = "Bearer {env:PARALLEL_API_KEY}";
            };
            plugin = [
              "@simonwjackson/opencode-direnv"
              "@tarquinen/opencode-dcp"
              "oh-my-opencode-slim@${omoVersion}"
              # "true-mem"
              "opencode-history-search"
              "openrtk"
            ];
            enabled_providers = [ "omniroute" ];
            # Store the gateway API key with OpenCode's /connect flow, outside
            # the Nix store. See OmniRoute's OpenCode integration guide:
            # https://omniroute.hagicode.com/en-US/frameworks/opencode/
            provider.omniroute = {
              npm = "@ai-sdk/openai-compatible";
              name = "OmniRoute";
              options.baseURL = "http://localhost:20128/v1";
              models = builtins.listToAttrs (
                map
                  (name: {
                    inherit name;
                    value = {
                      inherit name;
                      tool_call = true;
                      modalities = {
                        input = [ "text" ] ++ lib.optional (name != "Subagent") "image";
                        output = [ "text" ];
                      };
                      # Conservative client caps for heterogeneous combos;
                      # the gateway controls the actual upstream limits.
                      limit = {
                        context = 128000;
                        output = 16384;
                      };
                    };
                  })
                  [
                    "Kestral"
                    "Subagent"
                    "Fixer"
                    "High Effort"
                  ]
              );
            };
            model = models.kestral;
            small_model = models.subagent;
            autoupdate = false;
            # Core OpenCode LSP server configuration, not plugin configuration.
            lsp = lspServers;
            agent.build.permission.task = {
              "*" = "allow";
            };
            agent.plan.permission.task = {
              "*" = "allow";
            };
            agent.orchestrator.permission.glob = "deny";
          };
          # OpenCode 2 replaced tui.json with cli.json.
          cli = {
            scroll = {
              speed = 1;
              acceleration = true;
            };
            # Cache hit rate + token breakdown in the sidebar. A terminal
            # plugin, so it loads from cli.json and not settings.plugin — the
            # two lists are separate loaders and a terminal plugin listed in
            # the main one is silently ignored.
            plugins = [ "opencode-visual-cache" ];
            # Stylix and the catppuccin module are both disabled for opencode
            # above, so pick its built-in theme here.
            theme.name = "catppuccin";
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
          set -l envfile ${hmArgs.config.age.secrets.parallel.path}

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
        # Must be `dcp.jsonc`, not `dcp.json`. DCP's getConfigPaths() picks
        # the *first* of ~/.config/opencode/dcp.jsonc, then dcp.json — it does
        # not merge them. DCP's own first-run createDefaultConfig() writes a
        # schema-only dcp.jsonc, and that stub silently shadowed every value
        # below (manualMode fell back to off, the context limits to the stock
        # 50k/100k), which is what made every model compress constantly.
        # Home-manager moves the stale stub to dcp.jsonc.bkp on activation.
        xdg.configFile."opencode/dcp.jsonc".text = dcpConfig;
        # OpenCode replaces the cli.json symlink with a plain file whenever a
        # setting changes in the TUI. The second such backup then collides with
        # cli.json.bkp and fails home-manager activation, so overwrite instead;
        # TUI-only changes are discarded on the next switch.
        xdg.configFile."opencode/cli.json".force = true;
      };
  };
}

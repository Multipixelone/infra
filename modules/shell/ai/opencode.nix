{ config, ... }:
{
  # Keep bundled platform engines local; Impeccable's launcher can download a
  # version-pinned, checksum-verified engine into the user cache when missing.
  gitignore = [ "/.opencode/skills/impeccable/scripts/bin/" ];

  # Vendored upstream Impeccable files with no treefmt formatter: plain-text
  # version/checksum metadata and the POSIX/Windows launchers (kept
  # byte-identical to upstream rather than reformatted).
  perSystem.treefmt.settings.global.excludes = [
    ".opencode/skills/impeccable/scripts/VERSION"
    ".opencode/skills/impeccable/scripts/engine-checksums.txt"
    ".opencode/skills/impeccable/scripts/impeccable"
    ".opencode/skills/impeccable/scripts/impeccable.cmd"
  ];

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
        # Keep npm plugin and schema versions together, not in installers that
        # would overwrite Home Manager-managed files.
        omoVersion = "3.0.7";
        dcpVersion = "3.2.0";
        visualCacheVersion = "1.7.5";

        # ── Composable building blocks ──────────────────────────────────
        #
        # Models: reusable model identifiers keyed by short name.
        # Roles:  per-role skills/mcps (model-agnostic).
        # mkPreset: merges a model and optional variant onto the matching role.

        # All OmniRoute combos share a one-million-token context window.
        modelContextLimit = 1000000;

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
            # doc/code lookups to explorer instead of doing them itself.
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
          # OMO 3.0.7 aliases librarian to explorer; keep repo and external
          # research capabilities on the canonical explorer role.
          explorer = {
            skills = [
              "infra-navigation"
              "nix"
            ];
            mcps = [
              "nixos"
              "websearch"
              "context7"
              "grep_app"
            ];
          };
          designer = {
            skills = [ "agent-browser" ];
            mcps = [ ];
          };
          # Reusable implementation procedures; validator owns long-running checks.
          fixer = {
            skills = [
              "nix"
              "agent-run-long"
              "package-add"
              "service-add"
            ];
            mcps = [ "nixos" ];
          };
          # Custom agent forked from marketplace alvin/validator@1.0.1;
          # owns agent-run-long validation lanes.
          validator = {
            skills = [ "agent-run-long" ];
            mcps = [ ];
          };
          # Test author; execution is delegated to validator, so no
          # agent-run-long.
          tester = {
            skills = [ "nix" ];
            mcps = [ "nixos" ];
          };
          # grafana-local is only registered on Link; listing it here is a
          # capability filter, not provisioning.
          diagnostician = {
            skills = [ "nix" ];
            mcps = [
              "nixos"
              "grafana-local"
            ];
          };
          documenter = {
            skills = [ ];
            mcps = [ ];
          };
          secrets = {
            skills = [ "nix" ];
            mcps = [ "nixos" ];
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
          explorer.model = "subagent";
          designer.model = "high-effort";
          fixer.model = "fixer";
          validator.model = "fixer";
          tester.model = "fixer";
          diagnostician.model = "subagent";
          documenter.model = "high-effort";
          secrets.model = "high-effort";
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

        # Locally maintained fork of marketplace package alvin/validator@1.0.1
        # (MIT, by Alvin). Top-level `agents` keys that aren't built-ins are
        # custom agents; the model/skills come from the preset entry above.
        customAgents.validator = {
          description = "Runs tests, lint, typechecks, builds, and Nix validation via agent-run-long, returning concise failure evidence while keeping full logs on disk.";
          prompt = builtins.readFile ./prompts/validator.md;
          orchestratorPrompt = ''
            @validator — runs established builds, tests, lint, typechecks, and Nix validation; owns every `agent-run-long` task and returns PASS/FAIL/BLOCKED with commands, exit codes, excerpts, and log paths. Delegate: each independent long-running build, test, or CI validation lane to a separate background validator with non-overlapping scopes (serialize overlaps); the final required checks after writers are reconciled. Don't: trivial short checks that another agent is explicitly permitted to run without agent-run-long, writing or fixing tests or code, coverage/architecture/visual review.
          '';
          # Execution-only: shell + read, no file mutation.
          permission = {
            edit = "deny";
            write = "deny";
            apply_patch = "deny";
            ast_grep_replace = "deny";
          };
        };

        # Locally authored selective test author. Edit permissions are coarse;
        # prompt boundaries and diff review keep it to test-only scope.
        customAgents.tester = {
          description = "Selectively authors regression tests for realistic defects, extends existing coverage, and explains when no new tests are warranted; leaves production fixes and validation execution to their owners.";
          prompt = builtins.readFile ./prompts/tester.md;
          orchestratorPrompt = ''
            @tester — assesses existing coverage and authors only worthwhile tests, fixtures, and test-only helpers. Delegate the behavior/specification, changed scope, and non-overlapping write ownership; delegation authorizes test writing without approval per test. Accept an evidence-backed “no new tests.” Assign narrow check wiring explicitly or leave it to fixer. Production fixes belong to fixer; every agent-run-long task, build, Nix validation, VM/runtime run, and long/full check belongs to a background validator after relevant writers are reconciled. Tiny local test iteration requires explicit delegation and repository-policy permission. Don't: coverage quotas, redundant tests, implementation mirrors, blanket snapshots, new frameworks, or making tests accommodate implementation bugs.
          '';
          permission = {
            edit = "allow";
            write = "allow";
            apply_patch = "allow";
            ast_grep_replace = "allow";
          };
        };

        # Locally authored read-only investigator for Nix and service
        # failures. Bash is for reads; denials are not a shell sandbox.
        customAgents.diagnostician = {
          description = "Investigates Nix evaluation, build, activation, and service failures using scoped read-only evidence; returns causal hypotheses, owning paths, and the smallest discriminating next step.";
          prompt = builtins.readFile ./prompts/diagnostician.md;
          orchestratorPrompt = ''
            @diagnostician — investigates Nix evaluation/build/activation failures and service/runtime incidents using scoped read-only evidence. Delegate: CI/Nix check failures; unexplained service failures; firing infrastructure alerts. Supply the known error/logs, target/installable/unit, relevant revision/tree state, and authorized host/environment/time window where applicable. Returns facts, hypotheses, owning paths, and the smallest discriminating probe. Don't: routine repo mapping (@explorer), architecture decisions or difficult synthesis after evidence collection (@oracle), implementation (@fixer), or build/test/long-reproduction execution (background @validator). No deployment, restart, or debugger attachment. The orchestrator owns execution and repair handoffs.
          '';
          permission = {
            bash = "allow";
            edit = "deny";
            write = "deny";
            apply_patch = "deny";
            ast_grep_replace = "deny";
          };
        };

        # Documentation writer: read + file edits only, no shell, delegation,
        # or code-mode execution. The plugin maps bash to shell+bash and task
        # to subagent; host permission rules still merge on top.
        customAgents.documenter = {
          description = "Reconciles substantial project documentation, runbooks, and multi-file guides against source, configuration, and tests.";
          prompt = builtins.readFile ./prompts/documenter.md;
          orchestratorPrompt = ''
            @documenter — delegate substantial source-to-doc reconciliation, operational runbooks, architecture/migration guides, or coordinated documentation updates, including literal prose in existing generated-doc sources. Pass the requested outcome, scope/file constraints, non-overlapping file ownership, known evidence, and open questions; serialize edits to shared mixed Nix files with other writers. It can inspect local sources without a complete dossier. Keep short corrections or summaries already supported by your context in the orchestrator. Do not delegate implementation changes, generated-output edits, source comments/docstrings, or agent-policy/routing changes. Route required source wiring and regeneration to fixer, and checks to validator.
          '';
          permission = {
            "*" = "deny";
            # Validators keep evidence outside the repository in private run dirs.
            external_directory = {
              "*" = "deny";
              "/tmp/opencode/*" = "allow";
            };
            read = "allow";
            glob = "allow";
            grep = "allow";
            ast_grep_search = "allow";
            edit = "allow";
            write = "allow";
            apply_patch = "allow";
            bash = "deny";
            task = "deny";
            execute = "deny";
            ast_grep_replace = "deny";
          };
        };

        customAgents.secrets = {
          description = "Manages agenix recipient rules and safe new-secret generation without exposing plaintext; returns patch-ready infra wiring and user-only credential/rotation steps.";
          prompt = builtins.readFile ./prompts/secrets.md;
          color = "#d946ef";
          orchestratorPrompt = ''
            @secrets — owns agenix recipient rules, safe new generated secrets, and patch-ready NixOS/Home Manager secret wiring. Delegate secret creation, recipient changes, supplied-credential/rotation guidance, and agenix failures with consumer scope and non-secret facts only. Never pass plaintext credentials or private keys. Existing payload edits and rekeying remain user-only; infra edits belong to fixer.
          '';
          # OMO 3.0.7 accepts legacy maps, not core v2 rule arrays. Its server
          # adapter preserves resource order and maps bash to shell + bash;
          # core write/edit/patch tools all check the edit action.
          permission = {
            edit = {
              "*" = "deny";
              "/home/tunnel/Documents/Git/nix-secrets/secrets.nix" = "allow";
            };
            ast_grep_replace = "deny";
            bash = "ask";
            webfetch = "deny";
            websearch = "deny";
          };
        };

        # Render shared MCP definitions directly into native OpenCode V2 shape.
        # Home Manager's built-in integration still emits the old server map.
        mcpServers = lib.mapAttrs (
          _: server:
          let
            isRemote = (server.url or null) != null;
            enabled = lib.hm.mcp.resolveEnabled server;
            environment = lib.hm.mcp.renderEnv (path: "{file:${path}}") (server.env or { });
          in
          {
            type = if isRemote then "remote" else "local";
          }
          // (
            if isRemote then
              { inherit (server) url; }
            else
              { command = [ server.command ] ++ (server.args or [ ]); }
          )
          // lib.optionalAttrs (isRemote && (server.headers or { }) != { }) {
            inherit (server) headers;
          }
          // lib.optionalAttrs (!isRemote && environment != { }) { inherit environment; }
          // lib.optionalAttrs (enabled != null) { disabled = !enabled; }
        ) hmArgs.config.programs.mcp.servers;

        # ── Dynamic context pruning ─────────────────────────────────────
        #
        # Compaction throws away warm prompt context and consumes quota on the
        # next request. Rare and large beats frequent and small, so nudges stay
        # soft and per-model floors stay high while ceilings guard overflow.
        dcpConfig = builtins.toJSON {
          "$schema" =
            "https://raw.githubusercontent.com/Opencode-DCP/opencode-dynamic-context-pruning/v${dcpVersion}/dcp.schema.json";
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
          # 50k onward despite the much larger context windows. With the file
          # at the path DCP actually reads, the shared thresholds below apply
          # and nudging starts at 50% of the shared 1M-token window.
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
            # Numeric thresholds track 75%/50% of the shared context window.
            maxContextLimit = modelContextLimit * 3 / 4;
            minContextLimit = modelContextLimit / 2;
            # These are nudge thresholds, not compression targets. Below
            # modelMinLimits DCP stays silent; at or above it turn/iteration
            # reminders switch on; above modelMaxLimits it nudges hard every
            # nudgeFrequency fetches. So the min is where compression pressure
            # *starts* — keep it high or the session compresses all session.
            # nudgeFrequency counts fetches between nudges above the ceiling,
            # so higher = quieter. iterationNudgeThreshold is how many messages
            # after a user message before reminders resume, so higher is also
            # quieter. nudgeForce "soft" (the upstream default) makes
            # post-user-message compression less likely than "strong".
            nudgeFrequency = 10;
            iterationNudgeThreshold = 40;
            nudgeForce = "soft";
            protectedTools = [
              "subagent"
              "skill"
              "todowrite"
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
          agents = customAgents;
          # Disable OMO's duplicate code-search MCP; use shared grep_app instead.
          disabled_mcps = [ "gh_grep" ];
          # Enable observer agent (disabled by default upstream).
          disabled_agents = [ ];
          presets.omniroute.agents = presetOmniroute;
        };
      in
      {

        programs.fish.interactiveShellInit = lib.concatStringsSep "\n\n" [
          # fish
          ''
            # The hosted Parallel Search MCP expands PARALLEL_API_KEY from the
            # process environment. Export it session-wide so every opencode launch
            # inherits it (oc, ocd, bare `opencode`), not just ones wrapped by `ocd`.
            # This does not update an already-running shared server's environment.
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
          enableMcpIntegration = false;
          inherit (aiConfig) context;
          agents = if aiConfig.agentsDir == null then { } else aiConfig.agentsDir;
          skills = aiConfig.skillsDir;
          settings = {
            # Shared programs.mcp headers use Claude-style placeholders;
            # OpenCode expands {env:VAR} in the server process environment.
            mcp.servers = mcpServers // {
              websearch = {
                type = "remote";
                url = "https://search.parallel.ai/mcp";
                disabled = false;
                headers.Authorization = "Bearer {env:PARALLEL_API_KEY}";
              };
            };
            plugins = [
              "@tarquinen/opencode-dcp@${dcpVersion}"
              "oh-my-opencode-slim@${omoVersion}"
            ];
            policies = [
              {
                action = "provider.use";
                resource = "*";
                effect = "deny";
              }
              {
                action = "provider.use";
                resource = "omniroute";
                effect = "allow";
              }
            ];
            # Store the gateway API key with OpenCode's /connect flow, outside
            # the Nix store. See OmniRoute's OpenCode integration guide:
            # https://omniroute.hagicode.com/en-US/frameworks/opencode/
            providers.omniroute = {
              package = "aisdk:@ai-sdk/openai-compatible";
              name = "OmniRoute";
              # Every device (link included) goes through the published name so
              # the router is reached the same way everywhere, over TLS.
              settings.baseURL = "https://${config.flake.servicePublicationInventory.applications.ai.canonical}/v1";
              models = builtins.listToAttrs (
                map
                  (name: {
                    inherit name;
                    value = {
                      inherit name;
                      capabilities = {
                        tools = true;
                        input = [ "text" ] ++ lib.optional (name != "Subagent") "image";
                        output = [ "text" ];
                      };
                      # Explicit client limits for every OmniRoute combo.
                      limit = {
                        context = modelContextLimit;
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
            update = "disable";
            agents = {
              title.model = models.subagent;
              build.permissions = [
                {
                  action = "subagent";
                  resource = "*";
                  effect = "allow";
                }
              ];
              plan.permissions = [
                {
                  action = "subagent";
                  resource = "*";
                  effect = "allow";
                }
              ];
              orchestrator.permissions = [
                {
                  action = "glob";
                  resource = "*";
                  effect = "deny";
                }
              ];
            };
          };
          # Global terminal client configuration.
          cli = {
            scroll = {
              speed = 1;
              acceleration = true;
            };
            # Cache hit rate + token breakdown in the sidebar. A terminal
            # plugin, so it loads from cli.json and not settings.plugins — the
            # two lists are separate loaders and a terminal plugin listed in
            # the main one is silently ignored.
            plugins = [ "opencode-visual-cache@${visualCacheVersion}" ];
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

          # Inject launch-time MCP credentials into both client and private
          # server. An already-running shared server keeps its old environment;
          # setting client variables alone cannot refresh that server's secrets.
          set -l envfile ${hmArgs.config.age.secrets.parallel.path}

          # `command env` bypasses fish-grc's auto-alias on `env`, which
          # would otherwise wrap opencode's stdout in a line-based
          # colorizer and shred the TUI.
          command env (test -r $envfile; and string match -rv '^#|^$' < $envfile) \
            opencode --standalone $argv
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

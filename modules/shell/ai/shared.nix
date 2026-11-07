{
  lib,
  rootPath,
  inputs,
  ...
}:
{
  config.flake-file.inputs = {
    mcp-servers-nix = {
      url = "github:natsukium/mcp-servers-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  options.flake.aiConfig = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = { };
    description = "Shared configuration values for AI coding tools (claude-code, opencode, etc.)";
  };

  config = {
    flake.aiConfig = {
      # Agents now live in OMO customAgents; no shared Markdown directory.
      # Claude accepts null; OpenCode maps it to an empty agent set.
      agentsDir = null;
      skillsDir = builtins.path {
        path = rootPath + /docs/skills;
        name = "infra-skills";
      };
      context = ''
        ## Rules
        System config: Nix only in `/home/tunnel/Documents/Git/infra`. Read repo `CLAUDE.md` / `AGENTS.md` before edits.

        ## Commits
        Always use Conventional Commits: `type(scope): imperative summary`. Types: feat/fix/refactor/perf/docs/test/build/ci/chore/revert. Add a scope when useful (host/module); lowercase summary, no trailing period, header ≤72 characters. Explain why in the body when non-obvious; mark breaking changes with `!` and/or `BREAKING CHANGE:`. One logical change per commit.

        ## Env
        Nix-managed NixOS+HM. Shell-scripts: prefer fish (no bash syntax). Terminal: foot+zellij. Agent shell tools may differ from `$SHELL`; use the tool's actual interpreter. If a dev-shell load is needed, run `direnv exec . COMMAND` from the repo root; keep stderr visible. Inherited environment variables do not prove freshness.

        ## Long builds and tests (Linux)
        On Linux, load and use the `agent-run-long` skill before long builds, tests, or Nix validation. Invoke `agent-run-long --label NAME --timeout 30m -- COMMAND…` through the Bash tool with an outer timeout of at least `(inner seconds + 60) × 1000` milliseconds (30m: `1860000`). The helper owns logging, timing, status, excerpts, and cleanup; do not add wrappers. Keep full validation delegated to background validators; if unavailable, report the limitation.
      '';
    };

    # Share MCP definitions across clients. Claude Code and Codex use their HM
    # integrations; opencode.nix renders native V2 servers from the same source.
    flake.modules.homeManager.base = hmArgs: {
      imports = [ inputs.mcp-servers-nix.homeManagerModules.default ];
      # Holds PARALLEL_API_KEY, consumed by the websearch MCP server below and
      # by opencode.nix's fish exporter. The ciphertext is still filed under the
      # old ai/tavily.age name in the secrets repo -- websearch moved from Tavily
      # to Parallel and the file was reused rather than re-created. Renaming it
      # there means an agenix re-encrypt plus a lock bump, so the key is named
      # for its contents here and the stale path is called out rather than left
      # to be discovered by decrypting it.
      age.secrets."parallel".file = "${inputs.secrets}/ai/tavily.age";
      programs.mcp.enable = true;
      mcp-servers.programs = {
        context7.enable = true;
        github = {
          enable = true;
          envFile = hmArgs.config.age.secrets."gh".path;
        };
        nixos.enable = true;
      };
      mcp-servers.settings.servers = {
        grep_app = {
          type = "http";
          url = "https://mcp.grep.app";
        };
        websearch = {
          type = "http";
          url = "https://search.parallel.ai/mcp";
          headers.Authorization = "Bearer \${PARALLEL_API_KEY}";
        };
      };
    };
  };
}

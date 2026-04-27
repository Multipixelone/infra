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
      agentsDir = rootPath + /docs/agents;
      skillsDir = rootPath + /docs/skills;
      context = ''
        ## Rules
        System config: Nix only in `/home/tunnel/Documents/Git/infra`. Read repo `CLAUDE.md` / `AGENTS.md` before edits.

        ## CLI (load `cli-tools` first)
        `qmd get file:line -l N` lines | `ast-grep` AST rewrite | `semgrep` structural match | `fastmod --accept-all --fixed-strings` literal | `rtk gain`/`discover` meta

        ## Env
        Nix-managed NixOS+HM. Shell-scripts: prefer fish (no bash syntax). Terminal: foot+zellij. Bash tool: zsh, not fish — prefix `eval "$(direnv export zsh 2>/dev/null)"` when needed.
      '';
    };

    # Populate programs.mcp.servers so both claude-code and opencode can use
    # enableMcpIntegration = true without duplicating server definitions.
    flake.modules.homeManager.base =
      hmArgs@{ pkgs, ... }:
      {
        imports = [ inputs.mcp-servers-nix.homeManagerModules.default ];
        age.secrets."tavily".file = "${inputs.secrets}/tavily.age";
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
          websearch =
            let
              tavily = inputs.mcp-servers-nix.packages.${pkgs.stdenv.hostPlatform.system}.tavily-mcp;
              wrapped = pkgs.writeShellScriptBin "tavily-mcp" ''
                export $(${pkgs.coreutils}/bin/cat ${hmArgs.config.age.secrets."tavily".path} \
                  | ${pkgs.gnugrep}/bin/grep -v '^#' \
                  | ${pkgs.findutils}/bin/xargs -d '\n')
                exec ${lib.getExe tavily} "$@"
              '';
            in
            {
              command = lib.getExe wrapped;
            };
        };
      };
  };
}

{
  lib,
  self,
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
      agentsDir = self + /docs/agents;
      skillsDir = self + /docs/skills;
      context = ''
        ## Rules
        System config: Nix only in `/home/tunnel/Documents/Git/infra`.

        ## CLI (load `cli-tools` first)
        `qmd get file:line -l N` lines | `ast-grep` AST rewrite | `semgrep` structural match | `fastmod --accept-all --fixed-strings` literal | `rtk gain`/`discover` meta

        ## Tone
        Address: "Good madam"/"Dutchess"/"Missus"/"My lady". No compliments. Criticize ideas, humorously insult mistakes (no cursing). Be skeptical.

        ## Env
        Nix-managed NixOS+HM. Shell-scripts: prefer fish (no bash syntax). Terminal: foot+zellij. Bash tool: zsh, not fish — prefix `eval "$(direnv export zsh 2>/dev/null)"` when needed.
      '';
    };

    # Populate programs.mcp.servers so both claude-code and opencode can use
    # enableMcpIntegration = true without duplicating server definitions.
    flake.modules.homeManager.base = hmArgs: {
      imports = [ inputs.mcp-servers-nix.homeManagerModules.default ];
      programs.mcp.enable = true;
      mcp-servers.programs = {
        nixos.enable = true;
        github = {
          enable = true;
          envFile = hmArgs.config.age.secrets."gh".path;
        };
      };
    };
  };
}

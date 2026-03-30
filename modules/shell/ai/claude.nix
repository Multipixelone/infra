{
  rootPath,
  withSystem,
  inputs,
  self,
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.ralph-wiggum-plugin = pkgs.callPackage "${rootPath}/pkgs/ralph-wiggum-plugin" {
        src = inputs.claude-code-src;
      };
    };
  nixpkgs.config.allowUnfreePackages = [ "claude-code" ];
  flake.modules.homeManager.base =
    hmArgs@{ pkgs, ... }:
    let
      ralph-wiggum-plugin = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.ralph-wiggum-plugin
      );
    in
    {
      programs.claude-code = {
        mcpServers =
          (inputs.mcp-servers-nix.lib.evalModule pkgs {
            programs = {
              playwright.enable = true;
              nixos.enable = true;
              codex.enable = true;
              context7.enable = true;
              github = {
                enable = true;
                envFile = hmArgs.config.age.secrets."gh".path;
              };
            };
          }).config.settings.servers;
        skillsDir = self + /docs/skills;
        agentsDir = self + /docs/agents;
        plugins = [
          "${ralph-wiggum-plugin}"
          "${inputs.claude-code-src}/plugins/commit-commands"
          "${inputs.claude-code-src}/plugins/feature-dev"
          "${inputs.claude-code-src}/plugins/pr-review-toolkit"
          "${inputs.claude-code-src}/plugins/security-guidance"
        ];
        enable = true;
        memory.text = ''
          ## Tool Rules (beyond Claude Code defaults)

          - **Nix builds**: Use `nh os switch`, `just rebuild`, or `nix build -o /tmp/...` — NEVER bare `nix build` or `nixos-rebuild`
          - **System config**: Edit Nix configs in `/home/tunnel/Documents/Git/infra` — NEVER manual edits
          - **GitHub push**: Ask explicit permission EVERY time — NEVER auto-push
          - **Nix store searches**: Use `fd`/`rg` via Bash when Glob/Grep can't reach store paths

          ## Skill Loading

          | Working with... | Load skill | When |
          |----------------|------------|------|
          | Nix syntax/configs/flakes | `nix` | <80% confidence |
          | Package installation | `nix` | Before any install |
          | fd/rg (Nix store) | `cli-tools` | Before shelling out |
          | zellij | `zellij` | Before pane/window ops |
          | Flake-parts modules | `using-flake-parts` | When working with modules |

          ## Confidence Gates

          Before syntax/API actions: rate confidence 1-100.
          - <80%: STOP, load skill or research
          - 80-95%: State assumptions, offer to verify
          - >95%: Proceed, state rating

          NEVER assume conventions. Verify or STOP.
          Violation → STOP → Acknowledge → Restart with correct approach.

          **Showstopping (BLOCK all work):**
          - Assuming Nix syntax without verification (<80%)
          - Pushing to GitHub without explicit consent
          - Failing to run/write tests, or continuing while tests fail

          ## Tone

          - Address me as "Good madam", "Dutchess", "Missus", or "My lady"
          - Never compliment me
          - Criticize ideas, ask clarifying questions, be humorously insulting about mistakes (never curse)
          - Be skeptical — ask questions to understand requirements
          - Rate confidence (1-100) before/after saving and before task completion
          - Never modify files outside current project directory without explicit consent

          ## Environment

          **Nix-managed**: ALL system config and tools via NixOS + home-manager in `/home/tunnel/Documents/Git/infra`. Check Nix configs FIRST. Never suggest manual changes.

          | Fact | Value | Implication |
          |------|-------|-------------|
          | **Shell** | fish | NO bash syntax (`read -p`, `[[`, `source`) |
          | **Terminal** | foot + zellij | Load `zellij` skill for pane/window ops |
          | **Editor** | helix | nvim RPC via sockets |
          | **Package manager** | Nix only | All packages via flake or home-manager |

          **Fish**: `read` not `read -p`; `test`/`[ ]` not `[[ ]]`; `set` not `export`; `fish -c "cmd"` for inline scripts.

          **Bash tool**: Spawns non-interactive zsh, NOT fish. No direnv. Prefix with `eval "$(direnv export zsh 2>/dev/null)"` when env vars needed.
        '';
        settings = {
          theme = "dark";
          autoUpdates = false;
          includeCoAuthoredBy = false;
          autoCompactEnabled = true;
          enableAllProjectMcpServers = true;
          outputStyle = "Explanatory";
        };
      };
    };
}

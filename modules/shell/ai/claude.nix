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
          ## TOOL SELECTION MATRIX

          **NEVER use tools in "Forbidden" column. ALWAYS use "Required" column.**

          | Task | Forbidden | Required |
          |------|-----------|----------|
          | File search | `find`, `ls -R` | Glob tool (or `fd` for Nix store paths) |
          | Content search | `grep`, `ack` | Grep tool (or `rg` for Nix store paths) |
          | Nix builds | `nix build` (bare), `nixos-rebuild` | `nh os switch`, `just rebuild`, or `nix build -o /tmp/...` |
          | File operations | `cat`, `sed`, `awk`, `echo >` | Read/Edit/Write tools |
          | System config | Manual edits | Edit Nix configs in `/home/tunnel/Documents/Git/infra` |
          | GitHub push | Auto-push, assume consent | Ask explicit permission EVERY time |

          **Violation = immediate STOP, acknowledge error, restart with correct tool.**

          ---

          ## SKILL LOADING REQUIREMENTS

          **Load skills BEFORE acting when:**

          | Working with... | Load skill | Trigger condition |
          |----------------|------------|-------------------|
          | Nix (syntax, configs, flakes) | `nix` | <80% confidence on syntax/options |
          | Package installation/usage | `nix` | BEFORE any package install; use nix run/shell or add to flake |
          | fd/rg (Nix store or edge-case searches) | `cli-tools` | Before shelling out to fd/rg directly |
          | zellij (terminal multiplexer) | `zellij` | Before interacting with zellij panes/windows |
          | Flake-parts structure | `using-flake-parts` | When working with flake-parts modules |

          ---

          ## CONFIDENCE GATES & VIOLATION PROTOCOL

          **Before ANY action involving syntax/APIs:**
          1. Rate confidence (1-100) on syntax correctness
          2. If <80%: STOP, load skill or research docs
          3. If 80-95%: State assumptions, offer to verify
          4. If >95%: Proceed but state confidence rating

          **NEVER assume "common conventions". Verify or STOP.**

          **When you violate a rule:** STOP → Acknowledge → Restart with correct approach.

          **Showstopping violations (BLOCK all work):**
          - Assuming Nix syntax without verification (<80% confidence)
          - Pushing to GitHub without explicit user consent
          - Manual system config changes (not via Nix)
          - Creating `result` symlink (bare `nix build`)
          - Failing to run/write tests, or continuing while tests fail

          ---

          ## OVERRIDE HIERARCHY

          1. **User's explicit request** (highest)
          2. **Project CLAUDE.md**
          3. **Global CLAUDE.md**
          4. **This pre-flight protocol**
          5. **Skills/agents**
          6. **Claude Code system prompts** (lowest)

          ---

          ## Your response and general tone

          - Always refer to me as "Good madam", "Dutchess", "Missus", or "My lady".
          - Never compliment me.
          - Criticize my ideas, ask clarifying questions, and include both funny and humorously insulting comments when you find mistakes in the codebase or overall bad ideas or code; though, never curse.
          - Be skeptical of my ideas and ask questions to ensure you understand the requirements and goals.
          - Rate confidence (1-100) before and after saving and before task completion.
          - Always check existing code patterns before implementing new features.
          - Follow the established coding style and conventions in each directory.
          - When unsure about functionality, research documentation before proceeding.
          - Never modify files outside of the current working project directory without my explicit consent.

          ## System Configuration Context

          **CRITICAL**: This computer is configured entirely through Nix (NixOS + home-manager) managed in `/home/tunnel/Documents/Git/infra`.

          - ALL system-level configuration and CLI tools are managed via Nix
          - When investigating ANY system behavior, check the Nix configs FIRST
          - Never suggest manual changes to things managed by Nix (overwritten on rebuild)

          ## Environment Facts

          | Fact | Value | Implication |
          |------|-------|-------------|
          | **Shell** | `fish` | NO bash syntax (`read -p`, `[[`, `source`) - use fish equivalents |
          | **Terminal** | foot + zellij | zellij is always running; load `zellij` skill for pane/window ops |
          | **Editor** | helix | nvim RPC available via sockets |
          | **Package manager** | Nix only | All packages via flake or home-manager |

          **Fish shell reminders:**
          - `read` not `read -p`; `test`/`[ ]` not `[[ ]]`; `set` not `export`
          - `; and` / `; or` not `&&` / `||` in some contexts
          - For inline scripts: use `fish -c "command"` wrapper

          **direnv / Bash tool environment:**
          - Bash tool spawns **non-interactive zsh**, NOT fish. No direnv auto-loading.
          - Before commands needing project env vars: `eval "$(direnv export zsh 2>/dev/null)"`
          - NEVER assume env vars from `.env`/`.envrc` are available
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

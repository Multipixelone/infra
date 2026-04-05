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

      packages.claude-status-line = pkgs.writeShellApplication {
        name = "claude-status-line";
        runtimeInputs = [
          pkgs.jq
          pkgs.git
          pkgs.coreutils
          pkgs.inetutils
        ];
        text = ''
          input=$(cat)

          model=$(echo "$input" | jq -r '.model.display_name')
          current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
          project_dir=$(echo "$input" | jq -r '.workspace.project_dir')

          # Context window usage
          context_info=""
          usage=$(echo "$input" | jq '.context_window.current_usage')
          if [ "$usage" != "null" ]; then
              current=$(echo "$usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
              size=$(echo "$input" | jq '.context_window.context_window_size')
              if [ "$size" != "null" ] && [ "$size" -gt 0 ] 2>/dev/null; then
                  pct=$((current * 100 / size))
                  context_info=$(printf "💭 %d%%" "$pct")
              fi
          fi

          username=$(whoami)
          hostname=$(hostname -s 2>/dev/null || hostname)

          # Directory display (relative to project, else ~-abbreviated)
          if [ -n "$project_dir" ] && [ "$current_dir" != "$project_dir" ]; then
              display_dir=''${current_dir#"$project_dir"/}
              if [ "$display_dir" = "$current_dir" ]; then
                  display_dir=''${current_dir/#"$HOME"/~}
              fi
          else
              display_dir=''${current_dir/#"$HOME"/~}
          fi
          # Replace leading ~ with  icon
          display_dir=''${display_dir/#~/}

          # Git branch + dirty indicator
          git_info=""
          if git rev-parse --git-dir > /dev/null 2>&1; then
              branch=$(git branch --show-current 2>/dev/null)
              if [ -n "$branch" ]; then
                  git_status=""
                  if ! git diff-index --quiet HEAD -- 2>/dev/null; then
                      git_status=" 📝"
                  fi
                  # Catppuccin Mocha Green (#a6e3a1 ≈ 150)
                  git_info=$(printf " \033[2;38;5;150m %s\033[0m%s" "$branch" "$git_status")
              fi
          fi

          # Catppuccin Mocha Overlay0 separator (#6c7086 ≈ 60)
          sep=$'\033[2;38;5;60m\033[0m'

          # Catppuccin Mocha palette (256-color approximations):
          #   Mauve  (#cba6f7) ≈ 183  — ⚡ accent
          #   Blue   (#89b4fa) ≈ 111  — username
          #   Teal   (#94e2d5) ≈ 116  — hostname
          #   Overlay1 (#7f849c) ≈ 103 — directory / separators
          #   Lavender (#b4befe) ≈ 147 — model
          #   Overlay0 (#6c7086) ≈ 60  — context info
          printf "\033[38;5;183m⚡\033[0m %s \033[2;38;5;111m %s\033[0m\033[2;38;5;103m@\033[0m\033[2;38;5;116m💻 %s\033[0m %s \033[2;38;5;103m%s\033[0m%s %s \033[2;38;5;147m🧠 %s\033[0m \033[2;38;5;60m%s\033[0m" \
              "$sep" "$username" "$hostname" "$sep" "$display_dir" "$git_info" "$sep" "$model" "$context_info"
        '';
      };
    };
  nixpkgs.config.allowUnfreePackages = [ "claude-code" ];
  # FIXME get rid of this as soon as claude is updated upstream nixpkgs
  nixpkgs.overlays = [
    (final: prev: {
      claude-code = prev.claude-code.overrideAttrs (oldAttrs: rec {
        version = "2.1.92";
        src = final.fetchzip {
          url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
          hash = "sha256-CLLCtVK3TeXFZ8wBnRRHNc2MoUt7lTdMJwz8sZHpkFM=";
        };
        npmDepsHash = "sha256-5LvH7fG5pti2SiXHQqgRxfFpxaXxzrmGxIoPR4dGE+8=";
        postPatch = ''
          cp ${./claude-code-package-lock.json} package-lock.json
          substituteInPlace cli.js \
            --replace-fail '#!/bin/sh' '#!/usr/bin/env sh'
        '';
        # Must explicitly override npmDeps — overrideAttrs doesn't re-derive
        # it from the new src/postPatch/npmDepsHash
        npmDeps = final.fetchNpmDeps {
          inherit src postPatch;
          name = "claude-code-${version}-npm-deps";
          hash = npmDepsHash;
        };
      });
    })
  ];
  flake.modules.homeManager.base =
    hmArgs@{ pkgs, ... }:
    let
      ralph-wiggum-plugin = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.ralph-wiggum-plugin
      );
      claude-status-line = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.claude-status-line
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
          statusLine = {
            type = "command";
            command = "${claude-status-line}/bin/claude-status-line";
          };
        };
      };
    };
}

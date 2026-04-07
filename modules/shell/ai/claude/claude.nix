{
  rootPath,
  withSystem,
  inputs,
  self,
  lib,
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
  # FIXME get rid of this as soon as claude is updated upstream nixpkgs
  nixpkgs.overlays = [
    (final: prev: {
      claude-code = prev.claude-code.overrideAttrs (oldAttrs: rec {
        version = "2.1.92";
        src = final.fetchzip {
          url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
          hash = "sha256-CLLCtVK3TeXFZ8wBnRRHNc2MoUt7lTdMJwz8sZHpkFM=";
        };
        npmDepsHash = "sha256-PbTxKWooUILBLNnOCk96FkKr2MfnNi56V7Tdd5F+keE=";
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
      # ralph-wiggum-plugin = withSystem pkgs.stdenv.hostPlatform.system (
      #   psArgs: psArgs.config.packages.ralph-wiggum-plugin
      # );
      claude-status-line = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.claude-status-line
      );
      rtk-rewrite = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.rtk-rewrite
      );
    in
    {
      home.packages = [
        pkgs.rtk
        pkgs.ast-grep
        pkgs.semgrep
        pkgs.fastmod
      ];
      programs.claude-code = {
        mcpServers =
          (inputs.mcp-servers-nix.lib.evalModule pkgs {
            programs = {
              # playwright.enable = true;
              nixos.enable = true;
              # codex.enable = true;
              # context7.enable = true;
              github = {
                enable = true;
                envFile = hmArgs.config.age.secrets."gh".path;
              };
            };
          }).config.settings.servers;
        skillsDir = self + /docs/skills;
        agentsDir = self + /docs/agents;
        plugins = [
          # "${ralph-wiggum-plugin}"
          "${inputs.caveman}/plugins/caveman"
          "${inputs.claude-code-src}/plugins/commit-commands"
          # "${inputs.claude-code-src}/plugins/feature-dev"
          # "${inputs.claude-code-src}/plugins/pr-review-toolkit"
          # "${inputs.claude-code-src}/plugins/security-guidance"
        ];
        enable = true;
        memory.text = ''
          ## Tool Rules (beyond Claude Code defaults)

          - **Nix builds**: Use `nh os switch`, `just rebuild`, or `nix build -o /tmp/...` — NEVER bare `nix build` or `nixos-rebuild`
          - **System config**: Edit Nix configs in `/home/tunnel/Documents/Git/infra` — NEVER manual edits
          - **GitHub push**: Ask explicit permission EVERY time — NEVER auto-push
          - **Nix store searches**: Use `fd`/`rg` via Bash when Glob/Grep can't reach store paths

          ## Skill Loading

          All skills run on **haiku** for speed/cost. Complex work auto-escalates to the **nix agent** (sonnet).

          | Working with... | Load skill | When |
          |----------------|------------|------|
          | Nix syntax/configs/flakes | `nix` | <80% confidence |
          | Package installation | `package-add-flow` | Before any install |
          | Flake-parts modules | `using-flake-parts` | When working with modules |
          | Adding/configuring services | `service-add-flow` | Before adding services |
          | Secret management (agenix) | `secrets-flow` | Before touching secrets |
          | "Where is X configured?" | `infra-locate` | Navigation questions |
          | Check/CI failures | `check-triage` | After failed checks |
          | Option tracing | `option-trace-lite` | "Where is option X set?" |
          | CLI tools (qmd/ast-grep/semgrep/fastmod/rtk) | `cli-tools` | Before first use |

          ## CLI Tools (load `cli-tools` skill for full syntax)

          | Task | Tool | Quick syntax |
          |------|------|-------------|
          | Read specific lines | `qmd get <file>:<line> -l <N>` | Find line first: `rg -n <pattern> <file>` |
          | AST-aware code rewrite | `ast-grep` | Expressions, method calls |
          | Structural pattern match | `semgrep` | Metavariables `$X`, `$FUNC` |
          | Literal string replace | `fastmod --accept-all --fixed-strings` | Config keys, identifiers |
          | Token savings analytics | `rtk gain` / `rtk discover` | Meta commands only |

          ## Confidence Gates

          Rate 1-100 before syntax/API actions. <80%: STOP, load skill. 80-95%: state assumptions. >95%: proceed.

          **Showstopping (BLOCK all work):** Guessing Nix syntax (<80%), auto-pushing to GitHub, continuing with failing tests.

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
          **Bash tool**: Spawns non-interactive zsh, NOT fish. No direnv. Prefix `eval "$(direnv export zsh 2>/dev/null)"` when needed.
        '';
        settings = {
          theme = "dark";
          autoUpdates = false;
          includeCoAuthoredBy = false;
          autoCompactEnabled = true;
          enableAllProjectMcpServers = false;
          outputStyle = "Concise";
          hooks = {
            PreToolUse = [
              {
                matcher = "Bash";
                hooks = [
                  {
                    type = "command";
                    command = lib.getExe rtk-rewrite;
                  }
                ];
              }
            ];
          };
          statusLine = {
            type = "command";
            command = "${claude-status-line}/bin/claude-status-line";
          };
        };
      };
    };
}

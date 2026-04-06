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
      ralph-wiggum-plugin = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.ralph-wiggum-plugin
      );
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
          "${ralph-wiggum-plugin}"
          "${inputs.claude-code-src}/plugins/commit-commands"
          # "${inputs.claude-code-src}/plugins/feature-dev"
          # "${inputs.claude-code-src}/plugins/pr-review-toolkit"
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
          | Flake-parts modules | `using-flake-parts` | When working with modules |

          # Command Substitutes

          ## qmd

          **Usage**: Retrieve an exact passage from a source file by line range (99.2% token reduction).

          ```bash
          qmd get <file>:<line> -l <count>   # read N lines starting at line
          qmd get src/main/App.java:120 -l 30
          ```

          **When Claude should use this automatically:**
          - Any time you know the file and approximate line number
          - Before asking Claude to read a function — find the line with `rg -n` first, then `qmd get`
          - Never read a whole file when you only need one function

          **Expected output**: The exact source lines requested, nothing else. No surrounding context, no file header.

          ---

          ## ripgrep

          **Usage**: Find files containing a pattern before reading them (95.4% token reduction).

          ```bash
          rg -l <pattern> .              # list files containing pattern
          rg -n <pattern> <file>         # find exact line number in a file
          rg --type java <pattern> .     # restrict to file type
          ```

          **When Claude should use this automatically:**
          - Before reading any directory to find a file — always run ripgrep first
          - Before using `qmd get` — use `rg -n` to find the exact line number
          - Never use `find . -name` or directory listings to locate a file by content

          **Expected output**: For `-l`: one file path per line. For `-n`: `<file>:<line>:<match>` per line.

          ---

          ## ast-grep

          **Usage**: AST-aware search and structural rewrite (93.3% token reduction).

          ```bash
          ast-grep run --pattern '<pattern>' --lang <lang> .          # search
          ast-grep run --pattern '<old>' --rewrite '<new>' --lang <lang> -U .  # rewrite
          ```

          **When Claude should use this automatically:**
          - Renaming a method, function call, or expression across a codebase
          - When fastmod would match inside comments or strings (wrong)
          - Supported languages: Java, TypeScript, JavaScript, Python, Go, Rust, C, C++

          **Expected output**: Matched file paths with line numbers (search), or diff of rewrites (with `-U`).

          **When NOT to use ast-grep:**
          - Renaming a bare identifier across config files, YAML, or plain strings → use fastmod
          - The pattern is not a valid syntax fragment in the target language

          ---

          ## semgrep

          **Usage**: Lightweight static analysis and structural rewriting for many languages.

          ```bash
          semgrep scan --pattern '<pattern>' --lang <lang> .              # search
          semgrep scan --pattern '<pattern>' --lang <lang> --json .       # machine-readable output
          semgrep scan --config <rule.yaml> .                             # run a rule file
          ```

          **When Claude should use this automatically:**
          - The rewrite involves a structural pattern where arguments or expressions vary
          - Need to enforce or detect code patterns across a codebase
          - The target is too complex for fastmod but ast-grep's exact AST is too rigid
          - Use metavariables (`$X`, `$FUNC`, `$...ARGS`) to match arbitrary expressions

          **Expected output**: Matched findings with file, line, and matched code snippet.

          **When NOT to use semgrep:**
          - Simple literal string rename → use fastmod
          - Rename a specific method call with no argument variation → use ast-grep
          - Languages not supported by semgrep → use fastmod

          ---

          ## fastmod

          **Usage**: Fast literal string replacement across a codebase (65.1% token reduction).

          ```bash
          fastmod --accept-all --fixed-strings <old> <new> -e <ext> .
          fastmod --accept-all --fixed-strings old_name new_name -e java,yaml .
          ```

          **When Claude should use this automatically:**
          - Renaming a config key, underscore identifier, or any literal string across many files
          - When the text to replace is not a syntax expression (no method calls, no parentheses)
          - Use `--fixed-strings` to disable regex interpretation; use `-e` to restrict by extension

          **Expected output**: Number of replacements made, list of modified files.

          **When NOT to use fastmod:**
          - Renaming a method call or expression → use ast-grep
          - The pattern has structural variation (different argument shapes) → use semgrep

          ## RTK - Rust Token Killer

          **Usage**: Token-optimized CLI proxy (60-90% savings on dev operations)

          ### Meta Commands (always use rtk directly)

          ```bash
          rtk gain              # Show token savings analytics
          rtk gain --history    # Show command usage history with savings
          rtk discover          # Analyze Claude Code history for missed opportunities
          rtk proxy <cmd>       # Execute raw command without filtering (for debugging)
          ```

          ### Installation Verification

          ```bash
          rtk --version         # Should show: rtk X.Y.Z
          rtk gain              # Should work (not "command not found")
          which rtk             # Verify correct binary
          ```

          ### Hook-Based Usage

          All other commands are automatically rewritten by the Claude Code hook.
          Example: `git status` → `rtk git status` (transparent, 0 tokens overhead)

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

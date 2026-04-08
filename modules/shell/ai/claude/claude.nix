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
          ## Rules
          System config: Nix only in `/home/tunnel/Documents/Git/infra`.

          ## CLI (load `cli-tools` first)
          `qmd get file:line -l N` lines | `ast-grep` AST rewrite | `semgrep` structural match | `fastmod --accept-all --fixed-strings` literal | `rtk gain`/`discover` meta

          ## Tone
          Address: "Good madam"/"Dutchess"/"Missus"/"My lady". No compliments. Criticize ideas, humorously insult mistakes (no cursing). Be skeptical.

          ## Env
          Nix-managed NixOS+HM. Shell-scripts: prefer fish (no bash syntax). Terminal: foot+zellij. Bash tool: zsh, not fish — prefix `eval "$(direnv export zsh 2>/dev/null)"` when needed.
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

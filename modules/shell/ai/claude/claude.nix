{
  rootPath,
  withSystem,
  inputs,
  lib,
  config,
  ...
}:
{
  flake-file.inputs = {
    # caveman = {
    #   url = "github:JuliusBrussee/caveman";
    #   flake = false;
    # };
    claude-code-src = {
      url = "github:anthropics/claude-code";
      flake = false;
    };
    claude-code-pkg = {
      url = "github:ryoppippi/nix-claude-code";
    };
  };
  perSystem =
    { pkgs, ... }:
    {
      packages.ralph-wiggum-plugin = pkgs.callPackage "${rootPath}/pkgs/ralph-wiggum-plugin" {
        src = inputs.claude-code-src;
      };
    };
  nixpkgs.config.allowUnfreePackages = [ "claude-code" ];
  flake.modules.homeManager.base =
    { pkgs, ... }:
    let
      aiConfig = config.flake.aiConfig;
      # ralph-wiggum-plugin = withSystem pkgs.stdenv.hostPlatform.system (
      #   psArgs: psArgs.config.packages.ralph-wiggum-plugin
      # );
      claude-status-line = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.claude-status-line
      );
      rtk-rewrite = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.rtk-rewrite
      );

      inherit (pkgs.stdenv.hostPlatform) system;

      # OpenClaw's resolvePosixIdentity() refuses to bind a durable owner to any
      # executable whose shebang carries flags — `if (shebang &&
      # shebang.args.length > 0) return;` in dist/cli-auth-epoch-*.js — and
      # makeWrapper emits `#! …/bash -e`. That undefined propagates until the
      # gateway throws "CLI backend claude-cli executable cannot be bound to one
      # durable absolute owner", killing both the claude-cli inference backend
      # and the `openclaw` expert delegate tool.
      #
      # makeBinaryWrapper compiles a C wrapper instead, so bin/claude is an ELF
      # with no shebang at all. That takes resolvePosixIdentity's
      # self-contained-executable branch, which passes because the basename is
      # still `claude` — one of the backend policy's nativeExecutableNames.
      # Upstream's --argv0/--prefix PATH/--set/--set-default are all supported by
      # makeBinaryWrapper, so the gh + poppler-utils PATH entries and the three
      # DISABLE_* vars carry over unchanged.
      #
      # makeBinaryWrapper is taken from claude-code-pkg's own nixpkgs so the C
      # wrapper is compiled with the same stdenv as the rest of the derivation.
      claude-pkg = inputs.claude-code-pkg.packages.${system}.claude.override {
        makeWrapper = inputs.claude-code-pkg.inputs.nixpkgs.legacyPackages.${system}.makeBinaryWrapper;
      };
    in
    {
      home.packages = [
        pkgs.rtk
        pkgs.ast-grep
        pkgs.semgrep
        pkgs.fastmod
      ];
      programs.fish.shellAbbrs = {
        co = "claude --model opus --permission-mode auto";
      };
      programs.claude-code = {
        inherit (aiConfig) agentsDir context;
        skills = aiConfig.skillsDir;
        enableMcpIntegration = true;
        plugins = {
          # ralph-wiggum = "${ralph-wiggum-plugin}";
          # caveman = "${inputs.caveman}/plugins/caveman";
          commit-commands = "${inputs.claude-code-src}/plugins/commit-commands";
          # feature-dev = "${inputs.claude-code-src}/plugins/feature-dev";
          # pr-review-toolkit = "${inputs.claude-code-src}/plugins/pr-review-toolkit";
          # security-guidance = "${inputs.claude-code-src}/plugins/security-guidance";
        };
        enable = true;
        package = claude-pkg;
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

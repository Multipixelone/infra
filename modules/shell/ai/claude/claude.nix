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
    caveman = {
      url = "github:JuliusBrussee/caveman";
      flake = false;
    };
    claude-code-src = {
      url = "github:anthropics/claude-code";
      flake = false;
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
    in
    {
      home.packages = [
        pkgs.rtk
        pkgs.ast-grep
        pkgs.semgrep
        pkgs.fastmod
      ];
      programs.claude-code = {
        inherit (aiConfig) agentsDir context;
        skills = aiConfig.skillsDir;
        enableMcpIntegration = true;
        plugins = [
          # "${ralph-wiggum-plugin}"
          "${inputs.caveman}/plugins/caveman"
          "${inputs.claude-code-src}/plugins/commit-commands"
          # "${inputs.claude-code-src}/plugins/feature-dev"
          # "${inputs.claude-code-src}/plugins/pr-review-toolkit"
          # "${inputs.claude-code-src}/plugins/security-guidance"
        ];
        enable = true;
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

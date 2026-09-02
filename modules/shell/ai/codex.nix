{
  # OpenAI Codex — terminal coding agent, the OpenAI counterpart to Claude
  # Code. Apache-2.0, so no unfree allowlisting needed. Both packages are
  # cross-platform and pre-built in the binary cache for aarch64-darwin, so
  # this lands on the Mac (hylia) via the shared homeManager `base` module.
  #
  #   codex      — the CLI agent (`codex`); auth via ChatGPT login or
  #                OPENAI_API_KEY.
  #   codex-acp  — Agent Client Protocol adapter, so Codex can be driven from
  #                ACP-speaking editors (Zed, etc.) the same way as other agents.
  flake.modules.homeManager.base =
    { lib, pkgs, ... }:
    {
      # Use Home Manager's Codex module instead of installing the package
      # directly. This makes programs.mcp.servers the single source of truth,
      # just as it is for Claude Code and OpenCode.
      programs.codex = {
        enable = true;
        package = pkgs.codex;
        enableMcpIntegration = true;

        # Keep the existing Codex defaults under Home Manager ownership now
        # that it generates ~/.codex/config.toml.
        settings = {
          model = "gpt-5.6-sol";
          model_reasoning_effort = "medium";
          service_tier = "default";

          # Keep Codex sandboxed to the workspace, but allow local Git
          # operations that need to update the repository metadata.
          default_permissions = "workspace-git";
          permissions.workspace-git = {
            description = "Workspace editing with writable Git metadata";
            extends = ":workspace";
            filesystem.":workspace_roots".".git" = "write";
          };

          projects =
            lib.genAttrs
              [
                "/home/tunnel/Documents/Git/infra"
                "/home/tunnel/.openclaw"
                "/home/tunnel/Documents/Git/prem-tweet"
                "/home/tunnel/Documents/Finn"
                "/home/tunnel/.openclaw/workspace"
                "/home/tunnel/Documents/Git/docker"
                "/home/tunnel/Documents/Git/resume"
              ]
              (_: {
                trust_level = "trusted";
              });
        };
      };

      home.packages = [ pkgs.codex-acp ];
    };
}

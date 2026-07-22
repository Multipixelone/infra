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
    { pkgs, ... }:
    {
      home.packages = [
        pkgs.codex
        pkgs.codex-acp
      ];
    };
}

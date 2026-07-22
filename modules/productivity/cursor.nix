{
  # Cursor — AI-powered code editor (VS Code fork).
  #   macOS: installed via the `cursor` Homebrew cask (modules/hylia/homebrew.nix).
  #   Linux: installed from nixpkgs below.
  #
  # The Claude Code extension is intentionally not managed declaratively:
  # home-manager's programs.vscode does not target Cursor's config dirs, and
  # Cursor auto-installs the extension on first run of `claude` in its
  # integrated terminal — no config to drift or break across Cursor updates.
  nixpkgs.config.allowUnfreePackages = [ "cursor" ];

  flake.modules.homeManager.gui =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.code-cursor ];
    };
}

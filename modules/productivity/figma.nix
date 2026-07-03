{
  # macOS (hylia): the official Figma desktop app via homebrew. Merges into the
  # cask list declared in modules/hylia/homebrew.nix.
  configurations.darwin.hylia.module.homebrew.casks = [ "figma" ];

  # Linux desktops: the unofficial Electron build from nixpkgs, added to the
  # `gui` profile (not imported on darwin, so this never evaluates there).
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    {
      home.packages = [
        pkgs.figma-linux
      ];
    };
}

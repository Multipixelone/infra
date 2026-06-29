{ config, ... }:
let
  inherit (config.flake.meta.owner) username;
in
{
  # Ghostty has no nixpkgs build on darwin — the macOS app is a signed bundle
  # shipped by upstream (the binary cache only has linux), and there is no
  # `programs.ghostty` home-manager module. So the app itself comes from a
  # Homebrew cask; only the config is managed declaratively here, mirroring
  # foot's Catppuccin Mocha / PragmataPro setup.
  configurations.darwin.hylia.module = {
    homebrew.casks = [ "ghostty" ];
    home-manager.users.${username}.imports = [
      config.flake.modules.homeManager.ghostty
    ];
  };

  flake.modules.homeManager.ghostty = {
    # We write ghostty/config ourselves (Catppuccin Mocha to match foot), so
    # keep stylix off this target — same as foot.nix disables its target.
    stylix.targets.ghostty.enable = false;

    # Ghostty reads $XDG_CONFIG_HOME/ghostty/config on macOS too.
    xdg.configFile."ghostty/config".text = ''
      # Mirrors foot (Catppuccin Mocha, PragmataPro). Managed by Nix.

      # Font — foot: "PragmataPro Mono Liga:size=11"
      font-family = PragmataPro Mono Liga
      font-size = 14

      # Colors — Catppuccin Mocha (foot: catppuccin-mocha.ini)
      theme = Catppuccin Mocha

      # Transparency — foot: alpha = 0.85, alpha-mode = all
      background-opacity = 0.85

      # Native macOS background blur behind the translucent window
      # (no foot equivalent; true = default radius, or set a number).
      background-blur = 20

      # Padding — foot: pad = 4x4 center
      window-padding-x = 4
      window-padding-y = 4
      window-padding-balance = true

      # Cursor — foot: style = beam (ghostty has no beam-thickness knob)
      cursor-style = bar

      # Selection — foot: selection-target = clipboard
      copy-on-select = clipboard

      # URLs / OSC-8 — foot: osc8-underline = url-mode
      link-url = true

      # NOTE: ghostty's scrollback-limit is in BYTES (default ~10MB), not lines
      # like foot's 10000, so the generous default is left in place.
    '';
  };
}

{
  configurations.darwin.hylia.module = {
    # Declarative Brewfile via `brew bundle` on activation. Homebrew itself must
    # be installed once manually (https://brew.sh) before the first switch.
    homebrew = {
      enable = true;
      onActivation = {
        autoUpdate = true;
        upgrade = true;
        cleanup = "zap";
      };
      taps = [ ];
      brews = [ ];
      casks = [
        # Terminal
        "ghostty"

        # Browsers
        "firefox"

        # Notes & knowledge / study
        "obsidian"
        "anki"
        "zotero"

        # Communication
        "signal"
        "discord"
        "slack"
        "zoom"

        # Media
        "spotify"
        "plexamp"

        # Dev tooling
        "visual-studio-code"
        "docker-desktop"

        # Creative
        "adobe-creative-cloud"

        # Utilities
        "alfred"
        "rectangle"
        "itsycal"
        "1password"
        "vlc"

        # VPN (AmneziaWG protocol)
        "amneziavpn"
      ];
      masApps = { };
    };
  };
}

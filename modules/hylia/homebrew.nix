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
      taps = [
        "f/textream"
        "traycerai/traycer"
      ];
      brews = [
        # Newer Python than the macOS system one
        "python@3.13"
        # Apple Intelligence from the CLI, with OpenAI-compatible API server
        "apfel"
      ];
      casks = [
        # Terminal — ghostty cask is declared in modules/shell/terminal/ghostty.nix

        # Browsers
        "firefox"
        "google-chrome"

        # Notes & knowledge / study
        "obsidian"
        "anki"
        "zotero"

        # Communication
        "signal"
        "whatsapp"
        "telegram"
        "discord"
        "slack"
        "notion"
        "zoom"

        # Media
        "spotify"
        "plexamp"
        "moonlight" # Game streaming client (NVIDIA GameStream / Sunshine)

        # Dev tooling
        "visual-studio-code"
        "docker-desktop"
        "claude"
        # AI agent orchestration (from the traycerai/traycer tap)
        "traycerai/traycer/traycer-desktop"

        # Creative
        "adobe-creative-cloud"

        # Utilities
        "alfred"
        "rectangle"
        "itsycal"
        "1password"
        "vlc"
        "fluidvoice"

        # VPN (AmneziaWG protocol) (BUILT FOR INTEL ONLY)
        # "amneziavpn"

        # textream (from the f/textream tap)
        "f/textream/textream"
      ];
      # Mac App Store apps (ids from `mas list`). Pages and Keynote are
      # intentionally omitted — they ship preinstalled and are not managed here.
      masApps = {
        "BloonsTD6+" = 1584423325;
        "DaVinci Resolve" = 571213070;
        "Fantastical" = 975937182;
        "Final Cut Pro" = 424389933;
        "forScore" = 363738376;
        "GarageBand" = 682658836;
        "iMovie" = 408981434;
        "Mini Motorways" = 1456188526;
        "Logic Pro" = 634148309;
        "Numbers" = 361304891;
        "RCT Classic+" = 6702028686;
        "Todoist" = 585829637;
        "Xcode" = 497799835;
      };
    };
  };
}

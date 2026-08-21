{
  config,
  inputs,
  lib,
  ...
}:
let
  user = config.flake.meta.owner.username;
  encryptedProfile = "${inputs.secrets}/wireguard/hylia.age";
in
{
  configurations.darwin.hylia.module = {
    # The complete importable profile contains hylia's private key. Keep it in
    # the private secrets input and decrypt it into the user's secrets directory.
    # The guard lets infra and the secrets input be rolled forward independently.
    home-manager.users.${user}.age.secrets = lib.mkIf (builtins.pathExists encryptedProfile) {
      "wireguard/hylia-home-vpn.conf".file = encryptedProfile;
    };

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
        # Moonshot Kimi K3 native coding agent. Best-fidelity harness for K3:
        # preserves its reasoning-state "harness contract" that generic
        # agents degrade by truncating chain-of-thought.
        "kimi-code"
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
        "cursor"
        "docker-desktop"
        "claude"
        # Google Antigravity — agentic IDE + its terminal agent
        "antigravity-ide"
        "antigravity-cli"
        # Google Gemini desktop assistant (home of Gemini Omni media gen)
        "google-gemini"
        # AI agent orchestration (from the traycerai/traycer tap)
        "traycerai/traycer/traycer-desktop"
        # theo app
        "t3-app"
        # codex
        "chatgpt"

        # Creative
        "adobe-creative-cloud"

        # Utilities
        "alfred"
        "rectangle"
        "itsycal"
        "1password"
        "vlc"
        "fluidvoice"
        "auto-subs"

        # textream (from the f/textream tap)
        "f/textream/textream"
      ];
      # Mac App Store apps (ids from `mas list`). Pages and Keynote are
      # intentionally omitted — they ship preinstalled and are not managed here.
      masApps = {
        "AmneziaWG" = 6478942365;
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

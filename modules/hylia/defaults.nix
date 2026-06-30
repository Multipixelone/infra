{
  configurations.darwin.hylia.module = {
    # Declarative macOS preferences (`defaults write` equivalents).
    system.defaults = {
      dock = {
        autohide = true;
        show-recents = false;
        mru-spaces = false;
        tilesize = 48;
        wvous-br-corner = 14; # bottom-right hot corner → Quick Note
        # Declaratively pin the Dock contents (order = left→right). Any app not
        # listed here is removed from the Dock on activation.
        persistent-apps = [
          "/Applications/Firefox.app"
          { spacer = { small = true; }; }
          "/System/Applications/Messages.app"
          "/Applications/Slack.app"
          { spacer = { small = true; }; }
          "/Applications/Fantastical.app"
          "/Applications/Todoist.app"
          { spacer = { small = true; }; }
          "/Applications/Fluso.app"
          "/Applications/Notion.app"
          # NOTE: Adobe versions the path by year — bump on major upgrades.
          "/Applications/Adobe Premiere Pro 2026/Adobe Premiere Pro 2026.app"
          { spacer = { small = true; }; }
          "/Applications/Ghostty.app"
        ];
      };
      finder = {
        AppleShowAllExtensions = true;
        FXEnableExtensionChangeWarning = false;
        ShowPathbar = true;
        ShowStatusBar = true;
        _FXShowPosixPathInTitle = true;
        FXPreferredViewStyle = "Nlsv";
        FXDefaultSearchScope = "SCcf"; # search the current folder, not the whole Mac
        _FXSortFoldersFirst = true;
      };
      NSGlobalDomain = {
        AppleInterfaceStyle = "Dark";
        ApplePressAndHoldEnabled = false;
        InitialKeyRepeat = 15;
        KeyRepeat = 2;
        "com.apple.keyboard.fnState" = true;
        NSAutomaticCapitalizationEnabled = false;
        NSAutomaticSpellingCorrectionEnabled = false;
        NSAutomaticPeriodSubstitutionEnabled = false;
        NSNavPanelExpandedStateForSaveMode = true; # always-expanded save dialog
        PMPrintingExpandedStateForPrint = true; # always-expanded print dialog
      };
      menuExtraClock = {
        Show24Hour = true;
        ShowDayOfWeek = true;
        ShowDate = 0; # 0 = when space allows
      };
      WindowManager.HideDesktop = true; # hide items in Stage Manager
      screencapture = {
        location = "~/Pictures/Screenshots";
        type = "png";
      };
      loginwindow = {
        GuestEnabled = false;
      };
      trackpad.Clicking = true;
      # Neither key below has a typed nix-darwin option, so they go through
      # CustomUserPreferences (raw `defaults write`).
      CustomUserPreferences = {
        "com.apple.loginwindow".TALLogoutSavesState = false; # don't reopen apps/windows on next login
        # Disable Text Replacement substitution (e.g. emoticon → emoji).
        NSGlobalDomain.NSAutomaticTextReplacementEnabled = false;
      };
    };
  };
}

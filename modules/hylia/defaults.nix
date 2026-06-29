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
          "/System/Applications/Messages.app"
          "/Applications/Fluso.app"
          "/Applications/Fantastical.app"
          "/Applications/Todoist.app"
          # NOTE: Adobe versions the path by year — bump on major upgrades.
          "/Applications/Adobe Premiere Pro 2026/Adobe Premiere Pro 2026.app"
          "/Applications/Ghostty.app"
          "/Applications/Slack.app"
          "/Applications/Notion.app"
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
      loginwindow.GuestEnabled = false;
      trackpad.Clicking = true;
    };
  };
}

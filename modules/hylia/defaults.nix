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

{ config, ... }:
{
  configurations.darwin.hylia.module = {
    # Official macOS apps; Thunderbird is opened manually and owns its profiles.
    homebrew.casks = [
      "thunderbird"
      "proton-mail-bridge"
    ];

    # Use the signed app's hidden startup mode in the user's GUI session so
    # Keychain access, authentication, and app updates retain their normal flow.
    # Bridge's IMAP/SMTP listeners bind 127.0.0.1 upstream.
    # After GUI setup, disable Bridge's own "Open on startup" setting: its
    # app-managed LaunchAgent is separate from Home Manager's unique label.
    home-manager.users.${config.flake.meta.owner.username}.launchd.agents.proton-mail-bridge = {
      enable = true;
      config = {
        LimitLoadToSessionType = "Aqua";
        RunAtLoad = true;
        # `open` hands off to the app and exits; repeated launches can raise its
        # window. Let Bridge manage its own lifetime and remain quittable.
        KeepAlive = false;
        ProgramArguments = [
          "/usr/bin/open"
          "-g"
          "-a"
          "/Applications/Proton Mail Bridge.app"
          "--args"
          "--no-window"
        ];
      };
    };
  };
}

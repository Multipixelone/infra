{
  flake.modules.nixos.base = { options, ... }: {
    # Crash loops (MoonDeckBuddy, easyeffects, mangoapp) filled
    # /var/lib/systemd/coredump with 4.1G / 2558 dumps of the same cores.
    systemd.coredump.settings.Coredump = {
      MaxUse = "1G";
      KeepFree = "5G";
      MaxAge = "1week";
    };

    # Default SystemMaxUse is 10% of the filesystem, which let
    # /var/log/journal reach 3.9G on link.
    services.journald =
      if options.services.journald ? settings then
        {
          settings.Journal.SystemMaxUse = "1G";
        }
      else
        {
          extraConfig = "SystemMaxUse=1G";
        };
  };
}

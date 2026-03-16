{
  flake.modules.homeManager.gui = {
    programs.fish = {
      shellAliases = {
        decaf = "pkill -f 'systemd-inhibit.*Caffeine'";
      };
      functions.caffeine = {
        description = "Inhibit idle/sleep, optionally for a duration (e.g. caffeine 2h)";
        body = ''
          set duration $argv[1]
          if test -z "$duration"
            set duration inf
          end
          systemd-inhibit --what=idle:sleep --who=Caffeine --why=Caffeine --mode=block sleep $duration
        '';
      };
    };
  };
}

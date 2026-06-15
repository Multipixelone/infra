{
  configurations.nixos.link.module = {
    systemd.tmpfiles.rules = [
      "d /srv/slskd 0770 tunnel users -"
    ];
    virtualisation.oci-containers.containers.nicotine = {
      autoStart = true;
      image = "ghcr.io/fletchto99/nicotine-plus-docker:latest";
      ports = [
        "5031:6080"
        "2234:2234"
      ];
      # user = "1000:100";
      # TODO find some universal way to declare these paths like my music library so that I can use a variable
      volumes = [
        "/srv/slskd:/config"
        "/media/Data/Music/:/data/shared"
        "/media/Data/ImportMusic/slskd/:/data/downloads"
        "/media/Data/ImportMusic/InProgress:/data/incomplete_incomplete"
      ];
      environment = {
        PUID = "1000";
        PGID = "100";
      };
    };
    security = {
      polkit = {
        enable = true;
        extraConfig = ''
          polkit.addRule(function(action, subject) {
              if (action.id == "org.freedesktop.systemd1.manage-units") {
                  if (action.lookup("unit") == "podman-nicotine.service") {
                      var verb = action.lookup("verb");
                      if (verb == "start" || verb == "stop") {
                          return polkit.Result.YES;
                      }
                  }
              }
          });
        '';
      };
    };
  };
}

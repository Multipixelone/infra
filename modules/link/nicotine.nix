let
  # Shared by the container port mapping and the publication route below; the
  # route is resolved at flake level, where the NixOS module's own config is
  # out of scope, so the port cannot be read back from the container.
  webPort = 5031;
in
{
  # Published as nicotine.nyc.finnrut.is (internal only). Defined here rather
  # than in modules/service-publication/registry.nix so the noVNC host port has
  # one source of truth. slskd stays unpublished: it is the headless instance
  # Explo drives over its API.
  servicePublication.applications.nicotine = {
    site = "nyc";
    homepage = {
      group = "Downloads";
      name = "Nicotine+";
      description = "Soulseek client";
      icon = "nicotine-plus";
    };
    routes.root = {
      backend = {
        host = "link";
        port = webPort;
      };
      health = {
        # noVNC's page shell, served before the VNC session connects and
        # confirmed 200 without credentials against the running container.
        path = "/";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 8;
      };
    };
  };

  configurations.nixos.link.module = {
    infra.backup.srvPaths = [ "/srv/slskd" ];
    systemd.tmpfiles.rules = [
      "d /srv/slskd 0770 tunnel users -"
    ];
    virtualisation.oci-containers.containers.nicotine = {
      autoStart = true;
      image = "ghcr.io/fletchto99/nicotine-plus-docker:latest@sha256:1e5bedc221ea8f2c0941457f5ed929ef856305a0859c256df15ae2bc92e2bde0";
      ports = [
        "${toString webPort}:6080"
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

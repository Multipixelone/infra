let
  # Shared by the container port mapping and the publication route below; the
  # route is resolved at flake level, where the NixOS module's own config is
  # out of scope, so the port cannot be read back from the container.
  webPort = 5800;
in
{
  # Published as jdownloader.nyc.finnrut.is (internal only). Defined here rather
  # than in modules/service-publication/registry.nix so the web UI port has one
  # source of truth.
  servicePublication.applications.jdownloader = {
    site = "nyc";
    homepage = {
      name = "JDownloader";
      group = "Downloads";
      description = "Direct-download manager";
      icon = "jdownloader";
    };
    routes.root = {
      backend = {
        host = "link";
        port = webPort;
      };
      health = {
        # jlesage's web UI is noVNC; its page shell answers 200 without
        # credentials once the container is running.
        path = "/";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 8;
      };
    };
  };

  configurations.nixos.link.module = {
    infra.backup.srvPaths = [ "/srv/jdownloader" ];
    systemd.tmpfiles.rules = [
      "d /srv/jdownloader 0770 tunnel users -"
      "d /srv/deluge 0770 tunnel users -"
    ];

    virtualisation.oci-containers.containers.jdownloader = {
      autoStart = true;
      image = "jlesage/jdownloader-2:latest";
      ports = [ "${toString webPort}:5800" ];
      # user = "tunnel:users";
      # TODO find some universal way to declare these paths like my music library so that I can use a variable
      volumes = [
        "/media/Data/ImportMusic/JDownloader/:/output"
        "/srv/jdownloader/:/config"
      ];
    };
    virtualisation.oci-containers.containers.deluge = {
      autoStart = false;
      image = "linuxserver/deluge:latest";
      ports = [
        "8112:8112"
        "6881:6881"
        "6881:6881/udp"
        "58846:58846"
      ];
      # user = "tunnel:users";
      # TODO find some universal way to declare these paths like my music library so that I can use a variable
      volumes = [
        "/media/Data/ImportMusic/JDownloader/:/downloads"
        "/srv/deluge/:/config"
      ];
    };
  };
}

{
  configurations.nixos.link.module = {
    infra.backup.srvPaths = [ "/srv/jdownloader" ];
    systemd.tmpfiles.rules = [
      "d /srv/jdownloader 0770 tunnel users -"
      "d /srv/deluge 0770 tunnel users -"
    ];

    virtualisation.oci-containers.containers.jdownloader = {
      autoStart = false;
      image = "jlesage/jdownloader-2:latest";
      ports = [ "5800:5800" ];
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

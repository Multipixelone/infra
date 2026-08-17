{
  configurations.nixos.link.module = {
    infra.backup.srvPaths = [ "/srv/actual" ];
    networking.firewall.allowedTCPPorts = [ 5006 ];
    systemd = {
      tmpfiles.rules = [
        "d /srv/actual 0775 tunnel users -"
      ];
    };
    virtualisation.oci-containers = {
      containers = {
        actual-budget = {
          autoStart = true;
          image = "docker.io/actualbudget/actual-server:latest";
          ports = [ "5006:5006" ];
          volumes = [ "/srv/actual:/data" ];
        };
      };
    };
  };
}

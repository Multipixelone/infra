let
  # Shared by the firewall opening, the container port mapping and the
  # publication route below; the route is resolved at flake level, where the
  # NixOS module's own config is out of scope, so the port cannot be read back
  # from the container.
  webPort = 5006;
in
{
  # Published as actual.nyc.finnrut.is (internal only). Defined here rather than
  # in modules/service-publication/registry.nix so the container port has one
  # source of truth. Reaching it over the proxy's TLS also keeps Actual's
  # WebCrypto-dependent end-to-end encryption working, which a plain-HTTP LAN
  # origin does not.
  servicePublication.applications.actual = {
    site = "nyc";
    homepage = {
      name = "Actual Budget";
      group = "Finance";
      description = "Household budgeting and account sync";
      icon = "actual-budget";
    };
    routes.root = {
      backend = {
        host = "link";
        port = webPort;
      };
      health = {
        # Answers {"status":"UP"} without credentials; confirmed against the
        # running container. Note the SPA catch-all returns 200 for unknown
        # paths too, so a 200 here is only meaningful because /health is a
        # real route.
        path = "/health";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 8;
      };
    };
  };

  configurations.nixos.link.module = {
    infra.backup.srvPaths = [ "/srv/actual" ];
    networking.firewall.allowedTCPPorts = [ webPort ];
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
          ports = [ "${toString webPort}:5006" ];
          volumes = [ "/srv/actual:/data" ];
        };
      };
    };
  };
}

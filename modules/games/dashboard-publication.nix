{ config, lib, ... }:
let
  canonical = "games.nyc.finnrut.is";
  publicationEnabled = config.servicePublication.rollout.enableLocalCutover;
in
{
  servicePublication.applications.games = {
    site = "nyc";
    public = false;
    # Homepage integration belongs to the separately attended tiles change.
    homepage.enable = lib.mkDefault false;
    nginx.extraConfig = ''
      satisfy all;
      auth_basic "${canonical}";
      auth_basic_user_file /run/agenix/games/dashboard-htpasswd;
      client_max_body_size 4k;
      proxy_buffering off;
      proxy_cache off;
      gzip off;
      proxy_read_timeout 2700s;
    '';
    routes.root = {
      backend = {
        host = "link";
        port = 8780;
      };
      proxy.host = "link";
      health = {
        path = "/healthz";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 3;
      };
    };
  };

  configurations.nixos.link.module =
    { config, ... }:
    lib.mkIf publicationEnabled {
      # Copy the GENERATED private route ACL: trusted LANs AND VPN clients.
      # Only this exact minimal health endpoint is exempt from Basic auth.
      services.nginx.virtualHosts.${canonical}.locations."= /healthz" =
        let
          root = config.services.nginx.virtualHosts.${canonical}.locations."/";
        in
        {
          inherit (root) proxyPass proxyWebsockets;
          extraConfig = root.extraConfig + "\nauth_basic off;\n";
        };
    };
}

{ lib, ... }:
{
  servicePublication.applications.games = {
    site = "nyc";
    public = false;
    # Homepage integration belongs to the separately attended tiles change.
    homepage.enable = lib.mkDefault false;
    nginx.extraConfig = ''
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
}

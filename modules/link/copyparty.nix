{ inputs, ... }:
let
  # Shared by the firewall opening, the copyparty listener and the three
  # publication routes below; the routes are resolved at flake level, where the
  # NixOS module's own config is out of scope, so the port cannot be read back
  # from the service.
  webPort = 3923;

  backend = {
    host = "link";
    port = webPort;
  };
in
{
  # nixpkgs ships the package but no module, so the module comes from upstream's
  # own flake. It pins nixos-25.05, hence the follows; the module itself takes
  # pkgs from the host, so no overlay is needed.
  flake-file.inputs.copyparty = {
    url = "github:9001/copyparty";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  # Published as files.finnrut.is. Three routes rather than one, because
  # anonymous share links only work if Cloudflare Access is bypassed on the
  # prefixes they touch:
  #
  #   /        gated by the family policy — the browser and admin surface
  #   /share/  copyparty's share mountpoint, anonymous by design
  #   /.cpr/   the web UI's static assets, which a share page loads and which
  #            do not live under /share/, so a gated /.cpr/ renders every
  #            anonymous share unstyled and broken
  #
  # Cloudflare resolves the most specific path-scoped Access application first
  # and inherits nothing from the parent, so the narrower bypasses win over the
  # gated root without opening it.
  #
  # The bypass is a routing decision, not an authorization one: copyparty's own
  # README is emphatic that reverse-proxy rules are not sufficient. Anonymous
  # holds no permission on the volume below, and shares grant their own access
  # by mounting themselves under /share/ at runtime.
  servicePublication.applications.copyparty = {
    site = "nyc";
    public = true;
    publicHostname = "files.finnrut.is";
    homepage = {
      group = "Files";
      description = "File server and anonymous share links";
      icon = "copyparty";
    };
    access.policy = "family";
    # nginx defaults client_max_body_size to 1m, which would 413 uploads at our
    # own proxy long before Cloudflare's 100 MB request cap ever applied.
    # Buffering off keeps large uploads and streaming downloads from being
    # spooled to disk on the edge box first.
    nginx.extraConfig = ''
      client_max_body_size 1024M;
      proxy_request_buffering off;
      proxy_buffering off;
    '';
    routes.root = {
      inherit backend;
      health = {
        path = "/";
        # copyparty serves its login surface as a 200 rather than challenging
        # with a 401; observed against the running service on link.
        expectedStatuses = [ 200 ];
        timeoutSeconds = 8;
      };
    };
    routes.share = {
      # Trailing slash on purpose: an nginx prefix location is unanchored, so
      # /share would also capture /shared-secret. The Tunnel ingress regex is
      # anchored separately in infra/service-publication/main.tf.
      match.pathPrefix = "/share/";
      inherit backend;
      access = {
        bypassAccess = true;
        bypassJustification = "anonymous share links must resolve without an Access login; copyparty grants the access per share, not per path";
      };
      health = {
        path = "/share/";
        # The share mountpoint itself is not listable by anonymous, so copyparty
        # answers 403. That is the point of probing it: a 403 proves the bypass
        # carried the request all the way to copyparty, where an Access
        # challenge would have been a 302 to cloudflareaccess.com instead.
        # Probing an individual share would tie the health contract to a share
        # that can be revoked.
        expectedStatuses = [ 403 ];
        timeoutSeconds = 8;
      };
    };
    routes.assets = {
      match.pathPrefix = "/.cpr/";
      inherit backend;
      access = {
        bypassAccess = true;
        bypassJustification = "anonymous share pages load the web UI's static assets from /.cpr/, which is outside the share prefix";
      };
      health = {
        path = "/.cpr/ui.css";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 8;
      };
    };
  };

  configurations.nixos.link.module =
    { config, ... }:
    {
      imports = [ inputs.copyparty.nixosModules.default ];

      age.secrets."copyparty" = {
        file = "${inputs.secrets}/media/copyparty.age";
        mode = "400";
        owner = "tunnel";
        group = "users";
      };

      infra.backup.srvPaths = [ "/srv/copyparty" ];

      systemd.tmpfiles.rules = [
        "d /srv/copyparty 0775 tunnel users -"
      ];

      # Impa proxies this over the LAN, so the listener cannot be loopback-only.
      networking.firewall.allowedTCPPorts = [ webPort ];

      services.copyparty = {
        enable = true;
        # Run as the tunnel login user so shared files are owned tunnel:users,
        # matching every other service on this host and letting files be dropped
        # into the share directory without a chown.
        user = "tunnel";
        group = "users";
        # settings replaces the module's default attrset rather than merging
        # into it, so i/hist are restated here.
        settings = {
          i = "0.0.0.0";
          p = webPort;
          hist = "/var/cache/copyparty";
          # Share create/delete asks the broker to reload; leaving the module's
          # no-reload default in place would gate the feature this host exists
          # for.
          no-reload = false;
          # Mounts shares under /share/. copyparty validates this to be a single
          # toplevel segment and refuses to start otherwise, which is what makes
          # the prefix stable enough for an Access bypass to match.
          shr = "/share";
          # Base URL used when minting share links. Without it copyparty mints
          # them from the request Host, which is the internal alias for a
          # LAN-origin request.
          shr-site = "https://files.finnrut.is/";
          # The chain is Cloudflare edge -> cloudflared -> nginx on impa ->
          # here. Only the edge sets CF-Connecting-IP and it cannot be spoofed
          # past it, so trust that single-value header rather than the appended
          # X-Forwarded-For chain. Getting this wrong does not fail loudly:
          # copyparty falls back to the TCP address, disables unpost, and the
          # auto-ban system starts banning the proxy, i.e. everyone at once.
          xff-hdr = "cf-connecting-ip";
          xff-src = "lan";
          rproxy = 1;
          # nginx is https-only, and a missing X-Forwarded-Proto would otherwise
          # force copyparty's self.host to the literal "example.com" and poison
          # every generated share link.
          xf-proto-fb = "https";
          # Cap each up2k POST below Cloudflare's 100 MB request-body limit.
          # Upstream's default of 96 MiB sits within a rounding error of it;
          # only the chunked up2k uploader is bounded this way, so WebDAV PUT
          # and curl -T remain capped at 100 MB regardless.
          u2sz = 64;
        };
        accounts.admin.passwordFile = config.age.secrets."copyparty".path;
        volumes."/" = {
          # Dedicated and empty: nothing pre-existing is reachable even if an
          # ACL is wrong later.
          path = "/srv/copyparty";
          # No "*" entry, so anonymous holds nothing here and only the share
          # volumes copyparty mounts at runtime are reachable without a login.
          access.rwmda = [ "admin" ];
          # Expired shares are only reaped when the index is enabled on at least
          # one volume.
          flags.e2d = true;
        };
      };
    };
}

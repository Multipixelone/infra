{
  config,
  lib,
  ...
}:
let
  inherit (lib) mkOption types;
  publicationLib = import ../../lib/service-publication.nix { inherit lib; };

  capabilitiesType = types.submodule {
    options = {
      reverseProxy = mkOption {
        type = types.bool;
        default = false;
      };
      publicConnector = mkOption {
        type = types.bool;
        default = false;
      };
      internalDns = mkOption {
        type = types.bool;
        default = false;
      };
    };
  };

  accessType = types.submodule {
    options = {
      policy = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Access policy key. Public routes must resolve to an import-ready policy.";
      };
      serviceTokens = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Non-secret Cloudflare Access service-token identifiers.";
      };
      bypassAccess = mkOption {
        type = types.bool;
        default = false;
      };
      bypassJustification = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
    };
  };

  healthType = types.submodule {
    options = {
      path = mkOption {
        type = types.strMatching "/.*";
        description = "Backend health path.";
      };
      expectedStatuses = mkOption {
        type = types.nonEmptyListOf (types.ints.between 100 599);
      };
      timeoutSeconds = mkOption {
        type = types.ints.positive;
      };
    };
  };

  routeType = types.submodule {
    options = {
      match.pathPrefix = mkOption {
        type = types.strMatching "/.*";
        default = "/";
      };
      backend = {
        host = mkOption { type = types.str; };
        scheme = mkOption {
          type = types.enum [
            "http"
            "https"
          ];
          default = "http";
        };
        port = mkOption { type = types.port; };
      };
      proxy.host = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      public = mkOption {
        type = types.nullOr types.bool;
        default = null;
        description = "Null inherits the application setting; false may narrow a public application.";
      };
      access = mkOption {
        type = accessType;
        default = { };
      };
      health = mkOption {
        type = healthType;
        description = "Mandatory route health contract.";
      };
    };
  };

  applicationType = types.submodule (
    { name, ... }:
    {
      options = {
        site = mkOption { type = types.str; };
        public = mkOption {
          type = types.bool;
          default = false;
        };
        publicHostname = mkOption {
          type = types.nullOr types.str;
          default = null;
        };
        homepage = mkOption {
          type = types.submodule {
            options = {
              enable = mkOption {
                type = types.bool;
                default = true;
                description = "List this application on the Homepage dashboard.";
              };
              name = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Display name; defaults to the sentence-cased application key.";
              };
              group = mkOption {
                type = types.str;
                default = "Services";
                description = "Homepage group the application is listed under.";
              };
              description = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Short blurb rendered under the link.";
              };
              icon = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Homepage icon name (dashboard-icons), e.g. \"radarr\".";
              };
            };
          };
          default = { };
          description = "Presentation metadata for the Homepage dashboard. The inventory projection drops it, so it never reaches registry.json or OpenTofu.";
        };
        access = mkOption {
          type = accessType;
          default = { };
        };
        routes = mkOption {
          type = types.attrsOf routeType;
          description = "Routes keyed by stable route identity for ${name}.";
        };
      };
    }
  );

  siteType = types.submodule {
    options = {
      internalZone = mkOption {
        type = types.str;
      };
      routedLanCidrs = mkOption {
        type = types.listOf (types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+");
        default = [ ];
        description = "Confirmed LAN networks routed to VPN clients; empty until discovery is signed off.";
      };
      vpnClientCidrs = mkOption {
        type = types.listOf (types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+");
        default = [ ];
        description = "VPN client source networks accepted by generated DNS and proxy policy.";
      };
      trustedClientCidrs = mkOption {
        type = types.listOf (types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+");
        default = [ ];
        description = "Reviewed inbound client source networks allowed to reach generated DNS and proxy listeners; routed destinations are not implicitly trusted sources.";
      };
      dnsClientCidrs = mkOption {
        type = types.nonEmptyListOf (types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+/[0-9]+");
        description = "Client networks allowed to query the site's internal resolvers.";
      };
      networkInventoryConfirmed = mkOption {
        type = types.bool;
        default = false;
      };
      publicIngressHost = mkOption { type = types.str; };
      internalDnsHosts = mkOption {
        type = types.nonEmptyListOf types.str;
        description = "Ordered internal resolver hosts, primary first.";
      };
      connectorHosts = mkOption {
        type = types.nonEmptyListOf types.str;
        description = "Hosts concurrently running the adopted movable Tunnel connector during overlap.";
      };
      defaultProxyHosts = mkOption {
        type = types.listOf types.str;
        default = [ ];
      };
    };
  };

  publicationHostType = types.submodule {
    options = {
      site = mkOption { type = types.str; };
      addresses.lan = mkOption {
        type = types.nullOr types.str;
        default = null;
      };
      managedByNixOS = mkOption {
        type = types.bool;
        default = false;
      };
      capabilities = mkOption {
        type = capabilitiesType;
        default = { };
      };
      reachableFromProxyHosts = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Proxy hosts explicitly able to reach this host's declared LAN backends.";
      };
      deployedByColmena = mkOption {
        type = types.bool;
        default = false;
        description = "Whether colmena deploys this host, so it is expected to carry a generated /etc/service-publication/revision. False while a host is declared but not yet installed.";
      };
    };
  };

  accessPolicyType = types.submodule {
    options = {
      cloudflareImportKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Bootstrap-only existing resource ID, recorded when the policy body was read back from Cloudflare. Informational: no OpenTofu import block consumes it, it only marks the policy import-ready. Null keeps the policy unavailable for publication.";
      };
      decision = mkOption {
        type = types.enum [
          "allow"
          "deny"
          "non_identity"
          "bypass"
        ];
        default = "allow";
      };
      include = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
        description = "Reviewed, non-secret Cloudflare policy include rules discovered during adoption.";
      };
      exclude = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
      };
      require = mkOption {
        type = types.listOf types.attrs;
        default = [ ];
      };
      sessionDuration = mkOption {
        type = types.str;
        default = "24h";
      };
    };
  };

  # deployment-tags.nix only puts a host in the colmena hive when hosts.nix says
  # it is an installed, reachable NixOS host, and nixos.nix only writes
  # /etc/service-publication/revision on hosts carrying the resulting tag.
  # hosts.<name>.inHive is that membership test at its source, so reading it here
  # stays clear of the inventory the tag itself is derived from - reading the tag
  # back would be circular - and lets the deploy wrapper tell a host that is
  # merely declared from one that should have answered. A publication host with
  # no registry entry is a naming mistake, not a non-colmena host, so say so
  # instead of quietly reporting false.
  colmenaDeploys =
    name:
    config.hosts.${name}.inHive
      or (throw "servicePublication.hosts.${name} has no entry in the host registry (modules/hosts.nix); every publication host must be registered there so deployedByColmena is derived rather than assumed false");

  registry = config.servicePublication;
  inventory = publicationLib.resolve registry;
  rolloutErrors =
    lib.optional (
      registry.rollout.enableLocalCutover
      && !lib.all (site: site.networkInventoryConfirmed) (lib.attrValues registry.sites)
    ) "service publication: local cutover requires a confirmed network inventory for every site"
    ++
      lib.optional (registry.rollout.enableConnector && !registry.cloudflare.adoptionComplete)
        "service publication: connector enablement requires completed Cloudflare adoption and remote-state bootstrap"
    ++ lib.optionals registry.cloudflare.adoptionComplete (
      lib.optional (registry.cloudflare.accountId == null)
        "service publication: Cloudflare adoption cannot be completed without servicePublication.cloudflare.accountId"
      ++
        lib.optional (registry.cloudflare.zoneId == null)
          "service publication: Cloudflare adoption cannot be completed without servicePublication.cloudflare.zoneId"
      ++
        lib.optional (registry.cloudflare.tunnelName == null)
          "service publication: Cloudflare adoption cannot be completed without servicePublication.cloudflare.tunnelName"
    );
  checkedInventory =
    assert lib.assertMsg (inventory.errors ++ rolloutErrors == [ ]) (
      lib.concatStringsSep "\n" (inventory.errors ++ rolloutErrors)
    );
    inventory;
in
{
  options.servicePublication = {
    cloudflare = {
      accountId = mkOption {
        type = types.nullOr (types.strMatching ".+");
        default = null;
        description = "Non-secret Cloudflare account ID used by service-publication OpenTofu.";
      };
      zoneId = mkOption {
        type = types.nullOr (types.strMatching ".+");
        default = null;
        description = "Non-secret Cloudflare zone ID for finnrut.is.";
      };
      tunnelName = mkOption {
        type = types.nullOr (types.strMatching ".+");
        default = null;
        description = "Non-secret name of the existing adopted service-publication Tunnel.";
      };
      adoptionComplete = mkOption {
        type = types.bool;
        default = false;
        description = "True only after remote-state locking and a reviewed non-destructive adoption plan are proven.";
      };
    };
    rollout = {
      enableLocalCutover = mkOption {
        type = types.bool;
        default = false;
        description = "Enable generated Blocky/nginx/ACME/firewall/probe configuration after network discovery.";
      };
      enableConnector = mkOption {
        type = types.bool;
        default = false;
        description = "Enable the movable managed-Tunnel connector after adoption.";
      };
    };
    sites = mkOption {
      type = types.attrsOf siteType;
      default = { };
    };
    hosts = mkOption {
      type = types.attrsOf publicationHostType;
      default = { };
    };
    accessPolicies = mkOption {
      type = types.attrsOf accessPolicyType;
      default = { };
    };
    applications = mkOption {
      type = types.attrsOf applicationType;
      default = { };
    };
  };

  config = {
    servicePublication = {
      rollout.enableLocalCutover = true;
      rollout.enableConnector = true;

      # These are target identities, not permission to deploy. Access
      # policy bodies below were read back from the live Cloudflare account
      # and carry the existing resource IDs so adoption imports rather than
      # recreates them.
      cloudflare = {
        accountId = "4b74fb7e0a35c9c1148bf0434d7fdffa";
        zoneId = "d8bb324032c2738ff17efde63e9a7988";
        tunnelName = "link";
        adoptionComplete = true;
      };

      sites.nyc = {
        internalZone = "nyc.finnrut.is";
        routedLanCidrs = [
          "192.168.3.0/24"
          "192.168.5.0/24"
          "192.168.6.0/24"
          "192.168.7.0/24"
          "192.168.8.0/24"
        ];
        vpnClientCidrs = [ "10.100.0.0/24" ];
        trustedClientCidrs = [
          "192.168.3.0/24"
          "192.168.5.0/24"
          "192.168.6.0/24"
          "10.100.0.0/24"
        ];
        dnsClientCidrs = [
          "192.168.3.0/24"
          "192.168.5.0/24"
          "192.168.6.0/24"
          "192.168.7.0/24"
          "192.168.8.0/24"
        ];
        networkInventoryConfirmed = true;
        # Impa now carries public ingress and the default proxy. Link and Impa
        # both provide internal DNS during the migration, while both Tunnel
        # connectors remain active.
        publicIngressHost = "impa";
        internalDnsHosts = [
          "link"
          "impa"
        ];
        connectorHosts = [
          "link"
          "impa"
        ];
        defaultProxyHosts = [ "impa" ];
      };

      hosts = lib.mapAttrs (name: host: host // { deployedByColmena = colmenaDeploys name; }) {
        link = {
          site = "nyc";
          addresses.lan = config.hosts.link.homeAddress;
          managedByNixOS = true;
          capabilities = {
            reverseProxy = true;
            publicConnector = true;
            internalDns = true;
          };
          reachableFromProxyHosts = [
            "link"
            "impa"
          ];
        };
        impa = {
          site = "nyc";
          addresses.lan = config.hosts.impa.homeAddress;
          managedByNixOS = true;
          capabilities = {
            reverseProxy = true;
            publicConnector = true;
            internalDns = true;
          };
        };
        iot = {
          site = "nyc";
          addresses.lan = config.hosts.iot.homeAddress;
          managedByNixOS = true;
        };
        marin = {
          site = "nyc";
          addresses.lan = config.hosts.marin.homeAddress;
          managedByNixOS = true;
        };
        alexandria = {
          site = "nyc";
          addresses.lan = config.hosts.alexandria.homeAddress;
          managedByNixOS = false;
          # The Synology publishes its Docker ports on all NAS interfaces, so
          # the proxy needs no NAS-side firewall change.
          reachableFromProxyHosts = [
            "link"
            "impa"
          ];
        };
      };

      accessPolicies = {
        # Adopted from Cloudflare Access policy "Finn". The live policy also
        # includes a stale residential IP rule; identity is the only include
        # kept here, so adoption drops that rule.
        finn-only = {
          cloudflareImportKey = "c6e465cf-29f3-4579-a64f-4fbd6255e032";
          decision = "allow";
          include = [ { email.email = "finn@cnwr.net"; } ];
          require = [ { geo.country_code = "US"; } ];
          sessionDuration = "24h";
        };
        # Adopted from Cloudflare Access policy "Family".
        family = {
          cloudflareImportKey = "cb3f72d2-2cc4-4a09-b718-7db79eaa8249";
          decision = "allow";
          include = [
            { email_domain.domain = "cnwr.net"; }
            { email.email = "wrutis@gmail.com"; }
          ];
          require = [ { geo.country_code = "US"; } ];
          sessionDuration = "24h";
        };
      };

      applications = {
        grafana = {
          site = "nyc";
          homepage = {
            group = "Infrastructure";
            description = "Metrics, logs, alerts, and SLO drill-down";
            icon = "grafana";
          };
          routes.root = {
            backend = {
              host = "link";
              port = config.observability.endpoints.grafana.port;
            };
            health = {
              path = "/api/health";
              expectedStatuses = [ 200 ];
              timeoutSeconds = 8;
            };
          };
        };
        homepage = {
          site = "nyc";
          # The dashboard does not link to itself.
          homepage.enable = false;
          routes.root = {
            backend = {
              host = "link";
              port = config.observability.endpoints.homepage.port;
            };
            health = {
              path = "/";
              expectedStatuses = [ 200 ];
              timeoutSeconds = 8;
            };
          };
        };
        snapweb = {
          site = "nyc";
          homepage = {
            name = "Snapweb";
            group = "Media";
            description = "Private Snapcast control and listening UI";
            icon = "snapcast";
          };
          routes.root = {
            backend = {
              host = "link";
              port = 1780;
            };
            health = {
              path = "/";
              expectedStatuses = [ 200 ];
              timeoutSeconds = 8;
            };
          };
        };

        dsm = {
          site = "nyc";
          homepage = {
            name = "DSM";
            group = "Infrastructure";
            description = "Synology NAS system dashboard";
            icon = "synology";
          };
          routes.root = {
            backend = {
              host = "alexandria";
              port = 5000;
            };
            health = {
              # DSM unauthenticated entry points are served as login UI entry
              # points (e.g., /webman/login.cgi). Avoid URL fragments such
              # as #/signin: they are client-side and must not become proxy
              # paths.
              path = "/webman/login.cgi";
              expectedStatuses = [
                200
                302
              ];
              timeoutSeconds = 8;
            };
          };
        };

        notifiarr = {
          site = "nyc";
          homepage = {
            name = "Notifiarr";
            group = "Media";
            description = "Media automation notifications and integrations";
            icon = "notifiarr";
          };
          routes.root = {
            backend = {
              host = "alexandria";
              port = 5454;
            };
            health = {
              path = "/";
              expectedStatuses = [
                200
                302
              ];
              timeoutSeconds = 8;
            };
          };
        };

        # Synology Docker media stacks
        # (docker/compose-files/media-management/docker-compose.yml and
        # docker/compose-files/tautulli/docker-compose.yml). Ports are the
        # compose host-port mappings; alexandria is not NixOS-managed, so they
        # cannot be derived from Nix service config. The stacks were down when
        # registered, so the health contracts are the applications' documented
        # unauthenticated endpoints, not yet confirmed live. The
        # media-management cloudflared connector publishes no port and is not
        # a route; watchtower and kometa in the tautulli stack are portless
        # background jobs.
        plex = {
          site = "nyc";
          homepage = {
            group = "Media";
            description = "Private media library";
            icon = "plex";
          };
          routes.root = {
            backend = {
              host = "alexandria";
              port = 32400;
            };
            health = {
              # Confirmed from Link without a Plex token.
              path = "/identity";
              expectedStatuses = [ 200 ];
              timeoutSeconds = 8;
            };
          };
        };
        radarr = {
          site = "nyc";
          homepage = {
            group = "Media";
            description = "Movie collection automation";
            icon = "radarr";
          };
          routes.root = {
            backend = {
              host = "alexandria";
              port = 7878;
            };
            health = {
              path = "/ping";
              expectedStatuses = [ 200 ];
              timeoutSeconds = 8;
            };
          };
        };
        sonarr = {
          site = "nyc";
          homepage = {
            group = "Media";
            description = "TV collection automation";
            icon = "sonarr";
          };
          routes.root = {
            backend = {
              host = "alexandria";
              port = 8989;
            };
            health = {
              path = "/ping";
              expectedStatuses = [ 200 ];
              timeoutSeconds = 8;
            };
          };
        };
        # The compose service is still named overseerr, but the running app is
        # Seerr (the Overseerr successor). First public application in the
        # registry.
        seerr = {
          site = "nyc";
          public = true;
          publicHostname = "requests.finnrut.is";
          homepage = {
            group = "Media";
            description = "Movie and TV requests";
            # dashboard-icons has no seerr entry yet; the predecessor's mark
            # is the same app family.
            icon = "overseerr";
          };
          access.policy = "family";
          routes.root = {
            backend = {
              host = "alexandria";
              port = 5055;
            };
            health = {
              path = "/api/v1/status";
              expectedStatuses = [ 200 ];
              timeoutSeconds = 8;
            };
          };
        };
        nzbhydra2 = {
          site = "nyc";
          homepage = {
            group = "Downloads";
            name = "NZBHydra2";
            description = "Usenet meta search";
            icon = "nzbhydra2";
          };
          routes.root = {
            backend = {
              host = "alexandria";
              port = 5076;
            };
            health = {
              # The one actuator endpoint NZBHydra2 keeps permitAll in every
              # auth mode; plain / answers 302 once form/basic auth is enabled.
              path = "/actuator/health/ping";
              expectedStatuses = [ 200 ];
              timeoutSeconds = 8;
            };
          };
        };
        bazarr = {
          site = "nyc";
          homepage = {
            group = "Media";
            description = "Subtitle automation";
            icon = "bazarr";
          };
          routes.root = {
            backend = {
              host = "alexandria";
              port = 6767;
            };
            health = {
              path = "/";
              expectedStatuses = [ 200 ];
              timeoutSeconds = 8;
            };
          };
        };
        # Host port 6789 is a persisted SABnzbd customization; the container's
        # default 8080 is not published. SABnzbd's hostname verification
        # rejects unknown Host headers before auth, so
        # sabnzbd.nyc.finnrut.is must be added to host_whitelist in the NAS's
        # sabnzbd.ini by hand before this route can answer through the proxy.
        sabnzbd = {
          site = "nyc";
          homepage = {
            group = "Downloads";
            name = "SABnzbd";
            description = "Usenet downloader";
            icon = "sabnzbd";
          };
          routes.root = {
            backend = {
              host = "alexandria";
              port = 6789;
            };
            health = {
              # Documented as needing neither auth nor an API key, unlike /,
              # which redirects to the login form when a UI password is set.
              path = "/api?mode=version";
              expectedStatuses = [ 200 ];
              timeoutSeconds = 8;
            };
          };
        };
        tautulli = {
          site = "nyc";
          homepage = {
            group = "Media";
            description = "Plex activity and history";
            icon = "tautulli";
          };
          routes.root = {
            backend = {
              host = "alexandria";
              port = 8181;
            };
            health = {
              path = "/status";
              expectedStatuses = [ 200 ];
              timeoutSeconds = 8;
            };
          };
        };
      };
    };

    flake.servicePublicationInventory = checkedInventory;
  };
}

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
      networkInventoryConfirmed = mkOption {
        type = types.bool;
        default = false;
      };
      publicIngressHost = mkOption { type = types.str; };
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
    };
  };

  accessPolicyType = types.submodule {
    options = {
      cloudflareImportKey = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Bootstrap-only existing resource ID. Null keeps the policy unavailable for publication.";
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
      # These are target identities, not permission to deploy. Policy
      # definitions intentionally remain empty until Finn confirms the
      # adoption inputs documented in the runbook.
      cloudflare = {
        accountId = "4b74fb7e0a35c9c1148bf0434d7fdffa";
        zoneId = "d8bb324032c2738ff17efde63e9a7988";
        adoptionComplete = false;
      };

      sites.nyc = {
        internalZone = "nyc.finnrut.is";
        routedLanCidrs = [
          "192.168.5.0/24"
          "192.168.6.0/24"
          "192.168.7.0/24"
          "192.168.8.0/24"
        ];
        vpnClientCidrs = [ "10.100.0.0/24" ];
        networkInventoryConfirmed = true;
        publicIngressHost = "link";
        defaultProxyHosts = [ "link" ];
      };

      hosts = {
        link = {
          site = "nyc";
          addresses.lan = config.hosts.link.homeAddress;
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
        };
      };

      accessPolicies = {
        finn-only = { };
        family = { };
      };

      applications = {
        grafana = {
          site = "nyc";
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
      };
    };

    flake.servicePublicationInventory = checkedInventory;
  };
}

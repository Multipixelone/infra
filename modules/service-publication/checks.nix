{
  config,
  lib,
  ...
}:
let
  publicationLib = import ../../lib/service-publication.nix { inherit lib; };
  registry = config.servicePublication;
  inventory = config.flake.servicePublicationInventory;

  hasError = needle: result: lib.any (lib.hasInfix needle) result.errors;

  privateRoutePublic = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          routes = registry.applications.grafana.routes // {
            root = registry.applications.grafana.routes.root // {
              public = true;
            };
          };
        };
      };
    }
  );

  unjustifiedBypass = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          access = registry.applications.grafana.access // {
            bypassAccess = true;
            bypassJustification = null;
          };
        };
      };
    }
  );

  legacyName = publicationLib.resolve (
    registry
    // {
      accessPolicies = registry.accessPolicies // {
        finn-only = registry.accessPolicies.finn-only // {
          cloudflareImportKey = "finn-only";
          include = [ { email.email = "placeholder@example.invalid"; } ];
        };
      };
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = true;
          publicHostname = "grafana.home.finnrut.is";
          access = registry.applications.grafana.access // {
            policy = "finn-only";
          };
        };
      };
    }
  );

  outOfZoneHostname = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = true;
          publicHostname = "wiki.example.org";
          access = registry.applications.grafana.access // {
            policy = "finn-only";
          };
        };
      };
    }
  );

  wideningBypass = publicationLib.resolve (
    registry
    // {
      accessPolicies = registry.accessPolicies // {
        finn-only = registry.accessPolicies.finn-only // {
          cloudflareImportKey = "finn-only";
          include = [ { email.email = "placeholder@example.invalid"; } ];
        };
      };
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = true;
          access = registry.applications.grafana.access // {
            policy = "finn-only";
          };
          routes = {
            root = registry.applications.grafana.routes.root // {
              access = registry.applications.grafana.routes.root.access // {
                bypassAccess = true;
                bypassJustification = "public status page";
              };
            };
            admin = registry.applications.grafana.routes.root // {
              match.pathPrefix = "/admin/";
              health = registry.applications.grafana.routes.root.health // {
                path = "/admin/health";
              };
            };
          };
        };
      };
    }
  );

  publicFixture = publicationLib.resolve (
    registry
    // {
      accessPolicies = registry.accessPolicies // {
        finn-only = registry.accessPolicies.finn-only // {
          cloudflareImportKey = "finn-only";
          include = [ { email.email = "placeholder@example.invalid"; } ];
        };
      };
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = true;
          access = registry.applications.grafana.access // {
            policy = "finn-only";
          };
          routes = registry.applications.grafana.routes // {
            admin = registry.applications.grafana.routes.root // {
              match.pathPrefix = "/admin/";
              public = false;
              health = registry.applications.grafana.routes.root.health // {
                path = "/admin/health";
              };
            };
          };
        };
      };
    }
  );

  applicationServiceToken = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = true;
          access = registry.applications.grafana.access // {
            policy = "finn-only";
            serviceTokens = [ "00000000-0000-0000-0000-000000000000" ];
          };
        };
      };
    }
  );

  routeAccessOverride = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = true;
          access = registry.applications.grafana.access // {
            policy = "finn-only";
          };
          routes = registry.applications.grafana.routes // {
            api = registry.applications.grafana.routes.root // {
              match.pathPrefix = "/api/";
              access = registry.applications.grafana.routes.root.access // {
                policy = "family";
              };
            };
          };
        };
      };
    }
  );

  unboundApplicationPolicy = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = true;
          routes = registry.applications.grafana.routes // {
            root = registry.applications.grafana.routes.root // {
              access = registry.applications.grafana.routes.root.access // {
                policy = "finn-only";
              };
            };
          };
        };
      };
    }
  );

  everyoneDefaultPolicy = publicationLib.resolve (
    registry
    // {
      accessPolicies = registry.accessPolicies // {
        family = registry.accessPolicies.family // {
          decision = "bypass";
          include = [ { everyone = { }; } ];
        };
      };
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = true;
          access = registry.applications.grafana.access // {
            policy = "family";
          };
        };
      };
    }
  );

  # marin declares no reachableFromProxyHosts, unlike alexandria, which the
  # real registry marks reachable from link.
  unreachableBackend = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        homepage = registry.applications.homepage // {
          routes.root = registry.applications.homepage.routes.root // {
            backend = registry.applications.homepage.routes.root.backend // {
              host = "marin";
            };
          };
        };
      };
    }
  );

  checkedInventory =
    assert lib.assertMsg (
      inventory.errors == [ ]
    ) "the accepted registry must evaluate without projection errors";
    assert lib.assertMsg (hasError "private application route" privateRoutePublic)
      "private route publication validation regressed";
    assert lib.assertMsg (hasError "bypassAccess requires" unjustifiedBypass)
      "Access bypass justification validation regressed";
    assert lib.assertMsg (hasError "legacy home.finnrut.is" legacyName)
      "legacy hostname projection validation regressed";
    assert lib.assertMsg (hasError "outside the managed finnrut.is zone" outOfZoneHostname)
      "managed-zone canonical hostname validation regressed";
    assert lib.assertMsg (hasError "narrow the bypass route pathPrefix" wideningBypass)
      "outer-route bypass widening validation regressed";
    assert lib.assertMsg (publicFixture.errors == [ ]) "valid public application fixture must resolve";
    assert lib.assertMsg (
      publicFixture.cloudflare.dnsRecords.grafana.accessDependency == "grafana"
      && (builtins.head publicFixture.cloudflare.tunnel.applications).ingress != [ ]
      && !(builtins.head (builtins.head publicFixture.cloudflare.tunnel.applications).ingress).noTlsVerify
    ) "public DNS/Tunnel projections must carry Access and verified direct-origin intent";
    assert lib.assertMsg (
      applicationServiceToken.errors == [ ]
      &&
        builtins.attrNames applicationServiceToken.cloudflare.accessApplications == [
          "grafana"
          "seerr"
        ]
      && applicationServiceToken.cloudflare.accessApplications.grafana.domain == "grafana.apps.finnrut.is"
    ) "an application-level Access setting must not duplicate its Access application";
    assert lib.assertMsg (
      routeAccessOverride.errors == [ ]
      &&
        builtins.attrNames routeAccessOverride.cloudflare.accessApplications == [
          "grafana"
          "grafana/api"
          "seerr"
        ]
      &&
        routeAccessOverride.cloudflare.accessApplications."grafana/api".domain
        == "grafana.apps.finnrut.is/api/"
    ) "a route-level Access override must keep its own Access application";
    assert lib.assertMsg
      (hasError "default Access policy is missing or unknown" unboundApplicationPolicy)
      "application-level default Access policy validation regressed";
    assert lib.assertMsg (hasError "includes an everyone rule" everyoneDefaultPolicy)
      "everyone-rule default Access policy validation regressed";
    assert lib.assertMsg (hasError "decides bypass" everyoneDefaultPolicy)
      "non-allow default Access policy validation regressed";
    assert lib.assertMsg (hasError "does not declare reachability" unreachableBackend)
      "remote backend reachability validation regressed";
    inventory;
in
{
  perSystem =
    { pkgs, ... }:
    {
      files.file."infra/service-publication/registry.json".text = builtins.toJSON checkedInventory + "\n";

      checks.service-publication-registry =
        pkgs.runCommand "service-publication-registry-check"
          {
            nativeBuildInputs = [ pkgs.jq ];
            registry = builtins.toJSON checkedInventory;
          }
          ''
            printf '%s\n' "$registry" > registry.json
            jq -e '
              .metadata.schemaVersion == 1 and
              .metadata.containsSecrets == false and
              .errors == [] and
              (.blockyRecords["grafana.nyc.finnrut.is"] == "192.168.6.50") and
              (.applications.plex.public == false) and
              (.applications.plex.canonical == "plex.nyc.finnrut.is") and
              (.routes["plex/root"].health.path == "/identity") and
              (.sites.nyc.internalDnsHosts == ["link", "impa"]) and
              (.sites.nyc.publicIngressHost == "impa") and
              (.cloudflare.tunnel.connectorHosts.nyc == ["link", "impa"]) and
              (.hosts.link.deployedByColmena == true) and
              (.hosts.impa.deployedByColmena == true) and
              (.hosts.alexandria.deployedByColmena == false) and
              (([.internalProbes[].resolverAddress] | unique | sort) == ["192.168.6.50", "192.168.6.6"]) and
              ([.internalProbes[] | select(.routeKey == "grafana/root")] | length == 2) and
              (.cloudflare.dnsRecords | keys == ["seerr"]) and
              (.cloudflare.dnsRecords.seerr.hostname == "requests.finnrut.is") and
              (.cloudflare.accessApplications.seerr.access.policy == "family") and
              ([paths(strings) as $p | getpath($p) | select(endswith(".home.finnrut.is"))] | length == 0)
            ' registry.json >/dev/null
            touch "$out"
          '';

      checks.service-publication-registry-generated =
        pkgs.runCommand "service-publication-registry-generated-check"
          {
            src = ../..;
            registry = builtins.toJSON checkedInventory + "\n";
          }
          ''
            set -euo pipefail
            printf '%s' "$registry" > expected-registry.json
            cmp expected-registry.json "$src/infra/service-publication/registry.json"
            touch "$out"
          '';
    };
}

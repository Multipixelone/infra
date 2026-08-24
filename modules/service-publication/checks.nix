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

  unreachableBackend = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        homepage = registry.applications.homepage // {
          routes.root = registry.applications.homepage.routes.root // {
            backend = registry.applications.homepage.routes.root.backend // {
              host = "alexandria";
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
    assert lib.assertMsg (publicFixture.errors == [ ]) "valid public application fixture must resolve";
    assert lib.assertMsg (
      publicFixture.cloudflare.dnsRecords.grafana.accessDependency == "grafana"
      && (builtins.head publicFixture.cloudflare.tunnel.applications).ingress != [ ]
      && !(builtins.head (builtins.head publicFixture.cloudflare.tunnel.applications).ingress).noTlsVerify
    ) "public DNS/Tunnel projections must carry Access and verified direct-origin intent";
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
              (.blockyRecords["grafana.nyc.finnrut.is"] == "192.168.6.6") and
              ([.internalProbes[].resolverAddress] | unique == ["192.168.6.6"]) and
              (.cloudflare.dnsRecords == {}) and
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

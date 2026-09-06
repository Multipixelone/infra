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
  hasAccessApplicationFor =
    application: result:
    lib.any (entry: entry.application == application) (
      builtins.attrValues result.cloudflare.accessApplications
    );
  wholeBypassAccess = {
    policy = null;
    serviceTokens = [ ];
    bypassAccess = true;
    bypassJustification = "the application owns authentication and must accept API clients without a Cloudflare Access login";
  };
  homeAssistantAllowedSourceCidrs = [
    "10.100.0.0/24"
    "192.168.3.0/24"
    "192.168.5.0/24"
    "192.168.6.0/24"
    "192.168.7.0/24"
    "192.168.8.0/24"
  ];
  iotFirewallCommands = config.flake.nixosConfigurations.iot.config.networking.firewall.extraCommands;
  hasIotFirewallAccept =
    port: cidr:
    lib.hasInfix "--dport ${toString port} -s ${cidr} -j nixos-fw-accept" iotFirewallCommands;

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

  # The supported inverse of wideningBypass: a narrower bypass nested inside a
  # protected parent. Cloudflare resolves the most specific path-scoped Access
  # application first and inherits nothing from the parent, so this is how an
  # anonymous share prefix coexists with a gated root.
  innerBypass = publicationLib.resolve (
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
            share = registry.applications.grafana.routes.root // {
              match.pathPrefix = "/share/";
              access = registry.applications.grafana.routes.root.access // {
                bypassAccess = true;
                bypassJustification = "anonymous share links";
              };
              health = registry.applications.grafana.routes.root.health // {
                path = "/share/";
              };
            };
          };
        };
      };
    }
  );

  publicBypass = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = true;
          access = registry.applications.grafana.access // wholeBypassAccess;
        };
      };
    }
  );

  wholeBypassWithPolicy = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = true;
          access = registry.applications.grafana.access // (wholeBypassAccess // { policy = "finn-only"; });
        };
      };
    }
  );

  wholeBypassWithServiceToken = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = true;
          access =
            registry.applications.grafana.access
            // (wholeBypassAccess // { serviceTokens = [ "00000000-0000-0000-0000-000000000000" ]; });
        };
      };
    }
  );

  wholeBypassWithRouteOverride = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = true;
          access = registry.applications.grafana.access // wholeBypassAccess;
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

  nonPublicWholeBypass = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = false;
          access = registry.applications.grafana.access // wholeBypassAccess;
        };
      };
    }
  );

  declaredWholeBypassApplications =
    lib.filter
      (
        name:
        builtins.hasAttr name registry.applications
        && registry.applications.${name}.public
        && registry.applications.${name}.access.bypassAccess
      )
      [
        "map"
        "homeassistant"
      ];

  unprotectedPublicApplication = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          public = true;
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

  # The option type already rejects this, but every fixture above proves that
  # `resolve` is reachable with attrsets the module system never saw. A
  # non-positive objective becomes `vector(0)` in the recording rule and pins
  # the endpoint permanently above its own SLO, so the projection rejects it
  # too.
  nonPositiveLatencyObjective = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        grafana = registry.applications.grafana // {
          latencyObjectiveSeconds = 0;
        };
      };
    }
  );

  backendAllowedSources = publicationLib.resolve (
    registry
    // {
      applications = registry.applications // {
        homepage = registry.applications.homepage // {
          routes.root = registry.applications.homepage.routes.root // {
            backend = registry.applications.homepage.routes.root.backend // {
              allowedSourceCidrs = [
                "192.0.2.0/24"
                "198.51.100.0/24"
                "192.0.2.0/24"
              ];
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
    # Asserted by property rather than by a full attrNames list: the fixture
    # resolves against the real registry, so every published application would
    # otherwise have to be restated here each time one is added.
    assert lib.assertMsg (
      innerBypass.errors == [ ]
      &&
        innerBypass.cloudflare.accessApplications."grafana/share".domain == "grafana.apps.finnrut.is/share/"
      && innerBypass.cloudflare.accessApplications."grafana/share".access.bypassAccess
      && !innerBypass.cloudflare.accessApplications.grafana.access.bypassAccess
    ) "a bypass nested inside a protected route must resolve and keep its own Access application";
    assert lib.assertMsg
      (
        publicBypass.errors == [ ]
        && !hasAccessApplicationFor "grafana" publicBypass
        && publicBypass.cloudflare.dnsRecords.grafana.accessDependency == null
        && (
          let
            tunnelApplication = builtins.head (
              lib.filter (application: application.key == "grafana") publicBypass.cloudflare.tunnel.applications
            );
          in
          tunnelApplication.key == "grafana"
          && tunnelApplication.accessDependency == null
          && tunnelApplication.ingress != [ ]
          && lib.all (ingress: ingress.accessDependency == null) tunnelApplication.ingress
        )
      )
      "a valid whole-application bypass must retain DNS/Tunnel ingress without any Access application or dependency";
    assert lib.assertMsg
      (hasError "whole-application bypass cannot declare an Access policy" wholeBypassWithPolicy)
      "whole-application bypass must reject an application Access policy";
    assert lib.assertMsg
      (hasError "whole-application bypass cannot declare Access service tokens" wholeBypassWithServiceToken)
      "whole-application bypass must reject application Access service tokens";
    assert lib.assertMsg
      (hasError "whole-application bypass cannot declare route Access overrides" wholeBypassWithRouteOverride)
      "whole-application bypass must reject route Access overrides";
    assert lib.assertMsg
      (hasError "whole-application bypass requires public = true" nonPublicWholeBypass)
      "whole-application bypass must reject private applications";
    assert lib.assertMsg
      (lib.all (
        application:
        let
          tunnelApplication = builtins.head (
            lib.filter (candidate: candidate.key == application) inventory.cloudflare.tunnel.applications
          );
        in
        builtins.hasAttr application inventory.cloudflare.dnsRecords
        && inventory.cloudflare.dnsRecords.${application}.accessDependency == null
        && !hasAccessApplicationFor application inventory
        && tunnelApplication.accessDependency == null
        && lib.all (ingress: ingress.accessDependency == null) tunnelApplication.ingress
      ) declaredWholeBypassApplications)
      "declared whole-application bypasses must retain DNS/Tunnel ingress without Access resources or dependencies";
    assert lib.assertMsg
      (hasError "public route has no known Access policy" unprotectedPublicApplication)
      "public applications without an Access bypass must require a policy";
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
          "copyparty"
          "copyparty/assets"
          "copyparty/share"
          "forgejo"
          "grafana"
          "romm"
          "romm/collections"
          "romm/config"
          "romm/deviceAuthInit"
          "romm/deviceAuthToken"
          "romm/devices"
          "romm/firmware"
          "romm/heartbeat"
          "romm/platforms"
          "romm/resources"
          "romm/roms"
          "romm/saves"
          "romm/sync"
          "romm/tokenExchange"
          "romm/usersMe"
          "seerr"
        ]
      && applicationServiceToken.cloudflare.accessApplications.grafana.domain == "grafana.apps.finnrut.is"
    ) "an application-level Access setting must not duplicate its Access application";
    assert lib.assertMsg (
      routeAccessOverride.errors == [ ]
      &&
        builtins.attrNames routeAccessOverride.cloudflare.accessApplications == [
          "copyparty"
          "copyparty/assets"
          "copyparty/share"
          "forgejo"
          "grafana"
          "grafana/api"
          "romm"
          "romm/collections"
          "romm/config"
          "romm/deviceAuthInit"
          "romm/deviceAuthToken"
          "romm/devices"
          "romm/firmware"
          "romm/heartbeat"
          "romm/platforms"
          "romm/resources"
          "romm/roms"
          "romm/saves"
          "romm/sync"
          "romm/tokenExchange"
          "romm/usersMe"
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
    assert lib.assertMsg
      (hasError "latencyObjectiveSeconds must be positive" nonPositiveLatencyObjective)
      "latency objective positivity validation regressed";
    assert lib.assertMsg (
      backendAllowedSources.errors == [ ]
      &&
        backendAllowedSources.routes."homepage/root".backend.allowedSourceCidrs == [
          "192.0.2.0/24"
          "198.51.100.0/24"
        ]
    ) "backend allowed-source CIDRs must project as a stable unique list";
    assert lib.assertMsg
      (
        inventory.routes."map/root".backend.allowedSourceCidrs == [ ]
        && inventory.routes."forgejo/root".backend.allowedSourceCidrs == [ ]
        &&
          inventory.routes."homeassistant/root".backend.allowedSourceCidrs == homeAssistantAllowedSourceCidrs
      )
      "backend allowed-source CIDRs must default empty and project Home Assistant's reviewed direct clients";
    assert lib.assertMsg
      (
        lib.all (cidr: hasIotFirewallAccept 8123 cidr) (
          [ "192.168.6.50/32" ] ++ homeAssistantAllowedSourceCidrs
        )
        && hasIotFirewallAccept 80 "192.168.6.50/32"
        && lib.all (cidr: !hasIotFirewallAccept 80 cidr) homeAssistantAllowedSourceCidrs
        && !hasIotFirewallAccept 3000 "192.168.6.50/32"
      )
      "IoT remote-backend firewall rules must allow Home Assistant's proxy and direct clients without leaking them to other ports";
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
              (.cloudflare.dnsRecords | keys == ["copyparty", "forgejo", "homeassistant", "map", "romm", "seerr"]) and
              (.cloudflare.dnsRecords.seerr.hostname == "requests.finnrut.is") and
              (.cloudflare.accessApplications.seerr.access.policy == "family") and
              (.cloudflare.dnsRecords.forgejo.hostname == "git.finnrut.is") and
              (.cloudflare.accessApplications.forgejo.access.policy == "finn-only") and
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

{
  config,
  inputs,
  lib,
  ...
}:
let
  registry = config.servicePublication;
  inventory = config.flake.servicePublicationInventory;
  localEnabled = registry.rollout.enableLocalCutover;
  connectorEnabled = registry.rollout.enableConnector;
  acmeEmail = config.flake.meta.owner.email;
  runtimeAcmeSecret = "/run/agenix/cloudflare-acme-dns01";
  acmeSecret = "${inputs.secrets}/cloudflare/acme-dns01.age";
  connectorSecret = "${inputs.secrets}/cloudflare/service-publication-tunnel-token.age";
  hasAcmeSecret = builtins.pathExists acmeSecret;
  hasConnectorSecret = builtins.pathExists connectorSecret;

  configForHost =
    hostName: host:
    let
      proxyProjection = inventory.nginxByHost.${hostName} or null;
      site = registry.sites.${host.site};
      trustedCidrs = site.trustedClientCidrs;
      connectorHost = registry.hosts.${site.publicIngressHost};
      connectorIsRemote = site.publicIngressHost != hostName;
      publicOnProxy =
        proxyProjection != null
        && lib.any (
          vhost: vhost.kind == "proxy" && lib.any (route: route.public) vhost.routes
        ) proxyProjection.vhosts;
      allowedProxySources =
        trustedCidrs ++ lib.optional publicOnProxy "${connectorHost.addresses.lan}/32";
    in
    {
      module =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          acmeCertificateName = "service-publication-${hostName}";
          certificateNames = if proxyProjection == null then [ ] else proxyProjection.certificateNames;
          primaryCertificateName = if certificateNames == [ ] then null else builtins.head certificateNames;

          # Read back from the merged NixOS options instead of from
          # proxyProjection: certificateNames is derived from the very vhost
          # list it would otherwise be checked against, so an assertion phrased
          # in those terms re-derives its own expectation and can never fail.
          acmeCertificate = config.security.acme.certs.${acmeCertificateName} or null;
          acmeSanNames =
            if acmeCertificate == null then
              [ ]
            else
              [ acmeCertificate.domain ] ++ acmeCertificate.extraDomainNames;
          acmeVhostNames = lib.attrNames (
            lib.filterAttrs (
              _: vhost: vhost.useACMEHost == acmeCertificateName
            ) config.services.nginx.virtualHosts
          );

          nginxAcl = lib.concatMapStrings (cidr: "allow ${cidr};\n") trustedCidrs + "deny all;";
          nginxPublicAcl = lib.concatMapStrings (cidr: "allow ${cidr};\n") allowedProxySources + "deny all;";
          # Keeping the connector off an internal-only route is a source-address
          # rule, so it only means anything while the connector is a separate
          # host. When it runs on the proxy itself it dials the vhost over the
          # proxy's own LAN address, which is also the source address of the
          # generated health probe and of every other local client, so the deny
          # would 403 the probe rather than the connector. Non-public routes are
          # already answered with http_status:404 at the tunnel ingress.
          nginxInternalOnlyAcl =
            lib.optionalString (publicOnProxy && connectorIsRemote) "deny ${connectorHost.addresses.lan};\n"
            + nginxAcl;

          mkLocation = route: {
            proxyPass = "${route.backend.scheme}://${route.backendAddress}:${toString route.backend.port}";
            proxyWebsockets = true;
            extraConfig =
              if route.public then
                nginxPublicAcl
              else if registry.applications.${route.application}.public then
                nginxInternalOnlyAcl
              else
                nginxAcl;
          };

          mkVhost =
            vhost:
            if vhost.kind == "redirect" then
              {
                listen = [
                  {
                    addr = proxyProjection.lanAddress;
                    port = 443;
                    ssl = true;
                  }
                ];
                onlySSL = true;
                useACMEHost = acmeCertificateName;
                extraConfig = nginxAcl;
                locations."/".return = "308 https://${vhost.redirectTo}$request_uri";
              }
            else
              {
                listen = [
                  {
                    addr = proxyProjection.lanAddress;
                    port = 443;
                    ssl = true;
                  }
                ];
                onlySSL = true;
                useACMEHost = acmeCertificateName;
                locations = lib.listToAttrs (
                  map (route: lib.nameValuePair route.pathPrefix (mkLocation route)) vhost.routes
                );
              };

          generatedVhosts =
            if proxyProjection == null then
              { }
            else
              lib.listToAttrs (map (vhost: lib.nameValuePair vhost.name (mkVhost vhost)) proxyProjection.vhosts);

          proxyRoutes = lib.filterAttrs (_: route: route.proxy.host == hostName) inventory.routes;
          remoteBackendRoutes = lib.filterAttrs (
            _: route: route.backend.host == hostName && route.proxy.host != hostName
          ) inventory.routes;
          probeScript = pkgs.writeShellApplication {
            name = "service-publication-health-${hostName}";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.curl
            ];
            text = lib.concatMapStringsSep "\n" (
              route:
              let
                expected = lib.concatMapStringsSep "," toString route.health.expectedStatuses;
              in
              ''
                expected=${lib.escapeShellArg ",${expected},"}
                attempt=1
                while true; do
                  # Certificate reloads and restarted container backends are
                  # asynchronous during activation. Keep the probe bounded,
                  # but give routes a 30-attempt readiness window.
                  if ! status="$(curl --silent --show-error --output /dev/null \
                    --max-time ${toString route.health.timeoutSeconds} \
                    --resolve ${lib.escapeShellArg "${route.canonical}:443:${route.proxy.lanAddress}"} \
                    --write-out '%{http_code}' \
                    ${lib.escapeShellArg "https://${route.canonical}${route.health.path}"})"; then
                    status=000
                  fi
                  case "$expected" in
                    (*,"$status",*) break ;;
                  esac
                  if [ "$attempt" -ge 30 ]; then
                    echo ${lib.escapeShellArg "${route.key}: unexpected health status"} "$status" >&2
                    exit 1
                  fi
                  attempt=$((attempt + 1))
                  sleep 2
                done
              ''
            ) (lib.attrValues proxyRoutes);
          };

          protectedPorts = lib.unique (
            lib.optional (proxyProjection != null) 443
            ++ map (route: route.backend.port) (lib.attrValues remoteBackendRoutes)
          );
          firewallPorts = lib.concatMapStringsSep "," toString protectedPorts;
          # The chain is jumped to from position 1 of nixos-fw, ahead of the
          # loopback, trusted-interface and conntrack accepts nixpkgs appends,
          # so it has to re-accept loopback itself. Trusted interfaces are
          # deliberately not re-accepted: narrowing these ports to the site's
          # trusted client CIDRs is exactly what this chain exists for.
          firewallLoopbackAccept = "iptables -w -A nixos-service-publication -i lo -s 127.0.0.0/8 -j nixos-fw-accept";
          firewallAccepts =
            lib.concatMapStringsSep "\n" (
              cidr: "iptables -w -A nixos-service-publication -p tcp --dport 443 -s ${cidr} -j nixos-fw-accept"
            ) allowedProxySources
            + lib.optionalString (remoteBackendRoutes != { }) "\n"
            + lib.concatMapStringsSep "\n" (
              route:
              "iptables -w -A nixos-service-publication -p tcp --dport ${toString route.backend.port} -s ${route.proxy.lanAddress}/32 -j nixos-fw-accept"
            ) (lib.attrValues remoteBackendRoutes);
          connectorPackage = pkgs.cloudflared;
        in
        lib.mkMerge [
          (lib.mkIf (localEnabled && host.capabilities.internalDns) {
            services.blocky.settings.customDNS = {
              customTTL = "5m";
              mapping = lib.mkForce inventory.blockyRecords;
            };
            # Unknown internal names terminate locally instead of falling
            # through Blocky's public upstream chain.
            services.unbound.settings.server.local-zone = [ "${site.internalZone}. static" ];
          })

          (lib.mkIf (localEnabled && (proxyProjection != null || remoteBackendRoutes != { })) {
            assertions = [
              {
                assertion = proxyProjection == null || hasAcmeSecret;
                message = "service publication on ${hostName}: the separate ACME DNS-01 agenix secret is required";
              }
              {
                assertion = proxyProjection == null || acmeSanNames != [ ];
                message = "service publication on ${hostName}: a proxy must order a certificate with at least one name";
              }
              {
                assertion = lib.all (name: lib.elem name acmeSanNames) acmeVhostNames;
                message = "service publication on ${hostName}: every nginx vhost must be covered by its per-host SAN certificate";
              }
            ];

            age.secrets."cloudflare-acme-dns01" = lib.mkIf (proxyProjection != null) {
              file = acmeSecret;
              owner = "root";
              group = "root";
              mode = "0400";
            };

            security.acme = lib.mkIf (proxyProjection != null) {
              acceptTerms = true;
              defaults.email = acmeEmail;
              certs.${acmeCertificateName} = {
                domain = primaryCertificateName;
                extraDomainNames = builtins.tail certificateNames;
                dnsProvider = "cloudflare";
                environmentFile = runtimeAcmeSecret;
                group = "nginx";
              };
            };

            services.nginx = lib.mkIf (proxyProjection != null) {
              enable = true;
              recommendedGzipSettings = true;
              recommendedOptimisation = true;
              recommendedProxySettings = true;
              recommendedTlsSettings = true;
              virtualHosts = generatedVhosts;
            };

            systemd.services.service-publication-health = lib.mkIf (proxyProjection != null) {
              description = "Probe generated service-publication routes";
              # Ordering only: a queued certificate order must finish before a
              # probe runs, but a probe must never trigger an order itself.
              after = [
                "nginx.service"
                "acme-order-renew-${acmeCertificateName}.service"
              ];
              serviceConfig = {
                Type = "oneshot";
                ExecStart = lib.getExe probeScript;
              };
            };
            # The DNS-01 credential is consumed by the ordering unit; the base
            # unit only installs the bootstrap certificate nginx starts with.
            systemd.services."acme-order-renew-${acmeCertificateName}".unitConfig.ConditionPathExists =
              lib.mkIf (proxyProjection != null)
                runtimeAcmeSecret;
            systemd.timers.service-publication-health = lib.mkIf (proxyProjection != null) {
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnBootSec = "2m";
                OnUnitActiveSec = "1m";
                Unit = "service-publication-health.service";
              };
            };

            networking.firewall = lib.mkIf (protectedPorts != [ ]) {
              extraCommands = ''
                iptables -w -N nixos-service-publication 2>/dev/null || iptables -w -F nixos-service-publication
                ${firewallLoopbackAccept}
                ${firewallAccepts}
                iptables -w -A nixos-service-publication -j nixos-fw-refuse
                iptables -w -I nixos-fw 1 -p tcp -m multiport --dports ${firewallPorts} -j nixos-service-publication
              '';
              extraStopCommands = ''
                iptables -w -D nixos-fw -p tcp -m multiport --dports ${firewallPorts} -j nixos-service-publication 2>/dev/null || true
                iptables -w -F nixos-service-publication 2>/dev/null || true
                iptables -w -X nixos-service-publication 2>/dev/null || true
              '';
            };
          })

          (lib.mkIf (connectorEnabled && lib.elem hostName site.connectorHosts) {
            assertions = [
              {
                assertion = hasConnectorSecret;
                message = "service publication connector on ${hostName}: managed Tunnel token agenix secret is missing";
              }
              {
                assertion = host.capabilities.publicConnector;
                message = "service publication connector on ${hostName}: host lacks publicConnector capability";
              }
            ];

            age.secrets.service-publication-tunnel-token = {
              file = connectorSecret;
              owner = "cloudflared";
              group = "cloudflared";
              mode = "0400";
            };
            users.users.cloudflared = {
              group = "cloudflared";
              isSystemUser = true;
            };
            users.groups.cloudflared = { };
            systemd.services.service-publication-connector = {
              description = "Movable service-publication Cloudflare Tunnel connector";
              wantedBy = [ "multi-user.target" ];
              wants = [ "network-online.target" ];
              after = [ "network-online.target" ];
              serviceConfig = {
                ExecStart = "${lib.getExe connectorPackage} tunnel --no-autoupdate run --token-file ${config.age.secrets.service-publication-tunnel-token.path}";
                Restart = "always";
                User = "cloudflared";
                Group = "cloudflared";
              };
            };
          })
        ];
    };
in
{
  configurations.nixos = lib.mapAttrs configForHost (
    lib.filterAttrs (_: host: host.managedByNixOS) registry.hosts
  );
}

{
  config,
  inputs,
  lib,
  ...
}:
let
  ownerEmail = config.flake.meta.owner.email;
  journal = config.observability.journal;
  hostRegistry = config.hosts;
  hubHostName = config.observability.hubHost;
  hubAddress =
    if builtins.hasAttr hubHostName hostRegistry then hostRegistry.${hubHostName}.homeAddress else null;
  privateIpv4Octet = "(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])";
  privateIpv4 = "(10\\.${privateIpv4Octet}\\.${privateIpv4Octet}\\.${privateIpv4Octet}|172\\.(1[6-9]|2[0-9]|3[01])\\.${privateIpv4Octet}\\.${privateIpv4Octet}|192\\.168\\.${privateIpv4Octet}\\.${privateIpv4Octet})";
  validHubAddress = hubAddress != null && (builtins.match privateIpv4 hubAddress != null);
  sourceHasUnits =
    sourceServices:
    sourceServices != { } && lib.any (source: source.units != [ ]) (builtins.attrValues sourceServices);
  activeClientNames = builtins.filter (
    hostName:
    hostName != hubHostName
    && builtins.hasAttr hostName hostRegistry
    && hostRegistry.${hostName}.isNixOS
    && builtins.hasAttr hostName journal.sources
    && sourceHasUnits journal.sources.${hostName}
  ) (builtins.attrNames journal.clients);
  activeClients = map (
    hostName:
    let
      client = journal.clients.${hostName};
    in
    {
      address = if client.address == null then hostRegistry.${hostName}.homeAddress else client.address;
      inherit hostName;
    }
  ) activeClientNames;
  activeAddresses = map (client: client.address) activeClients;
  nginxClientAcl =
    lib.concatMapStrings (address: "allow ${address}/32;\n") activeAddresses + "deny all;";
  expectedHttpHostRegex = "^${lib.escapeRegex journal.ingress.fqdn}(?::${toString journal.ingress.port})?$";
  firewallChain = "nixos-journal-ingress";
  htpasswdSecretName = "journal-ingress-htpasswd";
  htpasswdAgeFile = "${inputs.secrets}/observability/${htpasswdSecretName}.age";
  htpasswdRuntimePath = "/run/agenix/${htpasswdSecretName}";
  cloudflareRuntimePath = "/run/agenix/cloudflare-acme-dns01";
  hasHtpasswdSecret = builtins.pathExists htpasswdAgeFile;
in
{
  # Central enrollment is owned by the hub ingress, not mqtt's producer
  # declaration. The first client shares the default credential; later clients
  # can select their own passwordSecret without changing the transport policy.
  observability.journal.clients.iot = { };

  configurations.nixos.${hubHostName}.module =
    { config, lib, ... }:
    {
      assertions = [
        {
          assertion = validHubAddress;
          message = "Journal ingress requires the observability hub to have a private IPv4 address.";
        }
        {
          assertion = lib.all (address: address != null) activeAddresses;
          message = "Every active journal client needs an effective source IPv4 address.";
        }
        {
          assertion = config.services.loki.configuration.server.http_listen_address == "127.0.0.1";
          message = "Journal ingress must proxy only to loopback Loki; Loki itself must remain loopback-only.";
        }
      ];
    }
    // lib.optionalAttrs validHubAddress {

      # Deliberately do not gate nginx.service on this new secret: nginx opens
      # auth_basic_user_file on request, so its absence fails this endpoint
      # closed without stopping Grafana or other established virtual hosts.
      age.secrets = lib.mkIf hasHtpasswdSecret {
        ${htpasswdSecretName} = {
          file = htpasswdAgeFile;
          owner = config.services.nginx.user;
          group = config.services.nginx.group;
          mode = "0400";
        };
      };

      security.acme = {
        acceptTerms = true;
        defaults.email = ownerEmail;
        certs.${journal.ingress.fqdn} = {
          domain = journal.ingress.fqdn;
          dnsProvider = "cloudflare";
          # Reuse Link's existing cloudflare-acme-dns01 agenix declaration.
          environmentFile = cloudflareRuntimePath;
          group = config.services.nginx.group;
        };
      };

      services.nginx = {
        enable = true;
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
        commonHttpConfig = ''
          limit_req_zone $binary_remote_addr zone=journal_ingress_rate:10m rate=10r/s;
          limit_conn_zone $binary_remote_addr zone=journal_ingress_conn:10m;
        '';
        virtualHosts.${journal.ingress.fqdn} = {
          # A dedicated private listener, intentionally independent of 443.
          listen = [
            {
              addr = hubAddress;
              port = journal.ingress.port;
              ssl = true;
              extraParameters = [ "default_server" ];
            }
          ];
          onlySSL = true;
          useACMEHost = journal.ingress.fqdn;
          extraConfig = ''
            access_log off;
            client_max_body_size 2m;
            if ($http_host !~ ${expectedHttpHostRegex}) { return 444; }
          '';
          locations."= /loki/api/v1/push" = {
            proxyPass = "http://127.0.0.1:3100";
            extraConfig = ''
              access_log off;
              if ($args != "") { return 404; }
              limit_req zone=journal_ingress_rate burst=20 nodelay;
              limit_conn journal_ingress_conn 4;
              ${nginxClientAcl}
              auth_basic "journal ingress";
              auth_basic_user_file ${htpasswdRuntimePath};
              limit_except POST { deny all; }
            '';
          };
          locations."/".return = "404";
        };
      };

      networking.firewall = {
        # Insert ahead of NixOS's broad trusted-interface/conntrack accepts.
        # Only active enrolled source /32s and loopback reach this port.
        extraCommands = ''
          iptables -w -N ${firewallChain} 2>/dev/null || iptables -w -F ${firewallChain}
          iptables -w -A ${firewallChain} -i lo -s 127.0.0.0/8 -j nixos-fw-accept
          ${lib.concatMapStringsSep "\n" (
            address:
            "iptables -w -A ${firewallChain} -p tcp --dport ${toString journal.ingress.port} -s ${address}/32 -j nixos-fw-accept"
          ) activeAddresses}
          iptables -w -A ${firewallChain} -j nixos-fw-refuse
          iptables -w -I nixos-fw 1 -p tcp --dport ${toString journal.ingress.port} -j ${firewallChain}
        '';
        extraStopCommands = ''
          iptables -w -D nixos-fw -p tcp --dport ${toString journal.ingress.port} -j ${firewallChain} 2>/dev/null || true
          iptables -w -F ${firewallChain} 2>/dev/null || true
          iptables -w -X ${firewallChain} 2>/dev/null || true
        '';
      };

      systemd.services."acme-order-renew-${journal.ingress.fqdn}".unitConfig.ConditionPathExists = [
        cloudflareRuntimePath
      ];
    };
}

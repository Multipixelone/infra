{ lib, config, ... }:
let
  inherit (config) observability;
  hostRegistry = config.hosts;
  publication = config.servicePublication;
  hub = config.hosts.${observability.hubHost};
  privateDnsRecords =
    observability.endpoints
    |> lib.filterAttrs (_: endpoint: endpoint.dnsName != null && endpoint.exposure == "private")
    |> lib.mapAttrs' (_: endpoint: lib.nameValuePair endpoint.dnsName hub.homeAddress);
in
{
  flake-file.inputs.blocklist = {
    url = "github:StevenBlack/hosts";
    flake = false;
  };

  flake.modules.nixos.edge =
    { lib, config, ... }:
    let
      dnscryptPort = 6000;
      unboundPort = 5335;
      isObservabilityHub = config.networking.hostName == observability.hubHost;
      isImpa = config.networking.hostName == "impa";
      lanAddress = (hostRegistry.${config.networking.hostName} or { homeAddress = null; }).homeAddress;
    in
    {
      # Disable systemd-resolved to allow blocky to bind to port 53
      services.resolved.enable = false;

      # Let blocky bind 10.100.0.1:53 (wg0's address) even before the wg0
      # interface is up, so a slow/failed WireGuard start can't take down the
      # whole DNS resolver. Without this, the missing address yields
      # "bind: cannot assign requested address" and blocky restart-loops.
      boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;

      # Use blocky on localhost for DNS resolution
      networking.nameservers = [
        "127.0.0.1"
        "::1"
      ];

      # Tell NetworkManager not to touch resolv.conf (blocky handles DNS)
      networking.networkmanager.dns = lib.mkForce "none";

      services.dnscrypt-proxy = {
        enable = true;
        settings = {
          listen_addresses = [ "127.0.0.1:${toString dnscryptPort}" ];
          ipv6_servers = true;
          require_dnssec = true;
          sources.public-resolvers = {
            urls = [
              "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"
              "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md"
            ];
            cache_file = "/var/lib/dnscrypt-proxy2/public-resolvers.md";
            minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
          };
        };
      };

      services.unbound = {
        enable = true;
        settings = {
          server = {
            interface = [
              "127.0.0.1"
              "::1"
            ];
            port = unboundPort;
            do-ip6 = true;
            access-control = [
              "127.0.0.0/8 allow"
              "::1/128 allow"
            ];
            num-threads = 2;
            msg-cache-slabs = 4;
            rrset-cache-slabs = 4;
            infra-cache-slabs = 4;
            key-cache-slabs = 4;
            cache-min-ttl = 3600;
            cache-max-ttl = 86400;
            hide-identity = true;
            hide-version = true;
            do-not-query-localhost = false; # required to forward to dnscrypt-proxy on localhost
          };

          forward-zone = [
            {
              name = ".";
              forward-addr = [ "127.0.0.1@${toString dnscryptPort}" ];
            }
          ];
        };
      };

      systemd.services.unbound = {
        after = [ "dnscrypt-proxy.service" ];
        requires = [ "dnscrypt-proxy.service" ];
      };

      services.blocky = {
        enable = true;
        settings = {
          ports.dns = [
            "127.0.0.1:53"
            "[::1]:53"
          ]
          ++ lib.optional (lanAddress != null) "${lanAddress}:53"
          ++ lib.optional isObservabilityHub "${hub.wireguard.ipv4Address}:53";

          ports.http =
            lib.mkIf (isObservabilityHub || isImpa)
              "${if isImpa then lanAddress else "127.0.0.1"}:${toString observability.endpoints.blocky.port}";

          customDNS = lib.mkIf isObservabilityHub {
            customTTL = "5m";
            mapping = privateDnsRecords;
          };

          prometheus.enable = isObservabilityHub || isImpa;

          upstreams.groups.default = [
            "127.0.0.1:${toString unboundPort}"
            "[::1]:${toString unboundPort}"
          ];

          # Start serving immediately if the upstream chain
          # (unbound→dnscrypt) isn't ready yet. On first boot dnscrypt may still
          # be fetching its resolver list; Blocky enables the upstreams once
          # the chain comes online.
          upstreams.init.strategy = "fast";

          # Resolve blocklist URLs (raw.githubusercontent.com, …) via unbound
          # directly instead of the system resolver, which is blocky itself —
          # that circular bootstrap is what produced the first-boot
          # "device or resource busy" download failures.
          bootstrapDns = [
            { upstream = "tcp+udp:127.0.0.1:${toString unboundPort}"; }
          ];

          blocking = {
            # Serve immediately and load denylists in the background; a failed
            # first download no longer aborts startup (it retries on refresh).
            loading.strategy = "fast";

            denylists = {
              ads = [
                "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
                "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro.txt"
              ];
              fakenews = [
                "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-only/hosts"
              ];
              gambling = [
                "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/gambling-only/hosts"
              ];
            };
            clientGroupsBlock.default = [
              "ads"
              "fakenews"
              "gambling"
            ];
            blockType = "zeroIp";
            blockTTL = "1m";
          };

          caching = {
            minTime = "5m";
            maxTime = "30m";
            prefetching = true;
          };
        };
      };

      networking.firewall = lib.mkIf (lanAddress != null) {
        extraCommands = ''
          iptables -w -N nixos-edge-dns 2>/dev/null || iptables -w -F nixos-edge-dns
          ${lib.concatMapStringsSep "\n" (cidr: "iptables -w -A nixos-edge-dns -s ${cidr} -j nixos-fw-accept")
            (
              publication.sites.nyc.dnsClientCidrs
              ++ lib.optionals isObservabilityHub publication.sites.nyc.vpnClientCidrs
            )
          }
          iptables -w -A nixos-edge-dns -j nixos-fw-refuse
          iptables -w -I nixos-fw 1 -p udp --dport 53 -j nixos-edge-dns
          iptables -w -I nixos-fw 1 -p tcp --dport 53 -j nixos-edge-dns
        '';
        extraStopCommands = ''
          iptables -w -D nixos-fw -p udp --dport 53 -j nixos-edge-dns 2>/dev/null || true
          iptables -w -D nixos-fw -p tcp --dport 53 -j nixos-edge-dns 2>/dev/null || true
          iptables -w -F nixos-edge-dns 2>/dev/null || true
          iptables -w -X nixos-edge-dns 2>/dev/null || true
        '';
      };

      systemd.services.blocky = {
        after = [
          "unbound.service"
        ]
        # On link, prefer to start after wg0 so 10.100.0.1 is normally present.
        # `wants` (not `requires`) + ip_nonlocal_bind means a wg0 failure
        # degrades gracefully instead of taking blocky down.
        ++ lib.optionals isObservabilityHub [ "wireguard-wg0.service" ];
        requires = [ "unbound.service" ];
        wants = lib.optionals isObservabilityHub [ "wireguard-wg0.service" ];
      };
    };

  flake.modules.nixos.pc = {
    imports = [ config.flake.modules.nixos.edge ];
  };
}

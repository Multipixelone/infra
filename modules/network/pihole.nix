{
  flake-file.inputs.blocklist = {
    url = "github:StevenBlack/hosts";
    flake = false;
  };

  flake.modules.nixos.pc =
    { lib, config, ... }:
    let
      dnscryptPort = 6000;
      unboundPort = 5335;
    in
    {
      # Disable systemd-resolved to allow blocky to bind to port 53
      services.resolved.enable = false;

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
          ]
          ++ lib.optionals (config.networking.hostName == "link") [ "10.100.0.1:53" ];

          upstreams.groups.default = [
            "127.0.0.1:${toString unboundPort}"
            "[::1]:${toString unboundPort}"
          ];

          blocking = {
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

      systemd.services.blocky = {
        after = [ "unbound.service" ];
        requires = [ "unbound.service" ];
      };
    };
}

{
  config,
  inputs,
  lib,
  ...
}:
let
  cfg = config.linkCache;
  ci = import ../../lib/ci.nix { inherit lib; };
  clients = ci.prebuild.hosts;
  fqdn = ci.prebuild.cacheHost;
  fqdnRegex = lib.replaceStrings [ "." ] [ "[.]" ] fqdn;
  address = config.hosts.link.homeAddress;
  clientAddresses = lib.concatMap (name: [
    config.hosts.${name}.homeAddress
    config.hosts.${name}.iotAddress
  ]) clients;
  sources = lib.unique (lib.filter (ip: ip != null) (clientAddresses ++ [ address ]));
  octet = "(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])";
  validIpv4 = ip: ip != null && builtins.match "${octet}\\.${octet}\\.${octet}\\.${octet}" ip != null;
  validAddress = validIpv4 address;
  linkSystem = config.flake.nixosConfigurations.link.config.nixpkgs.hostPlatform.system;
  secretFile = "${inputs.secrets}/nix-cache/link.age";
  secretPath = "/run/agenix/link-nix-cache-signing-key";
  validKey =
    cfg.publicKey != null && builtins.match "[A-Za-z0-9._-]+:[A-Za-z0-9+/]{43}=" cfg.publicKey != null;
  chain = "nixos-link-cache";
  prerequisites = [
    {
      assertion =
        validAddress
        && lib.all (name: validIpv4 config.hosts.${name}.homeAddress) clients
        && lib.all validIpv4 (lib.filter (ip: ip != null) clientAddresses);
      message = "Link cache requires valid Link/client home IPv4 addresses and valid declared IoT addresses in the host registry.";
    }
    {
      assertion = validKey;
      message = "linkCache.enable requires a provisioned Ed25519 cache public key.";
    }
    {
      assertion = builtins.pathExists secretFile;
      message = "linkCache.enable requires private nix-cache/link.age; provision it before enabling.";
    }
  ];
in
{
  options.linkCache = {
    enable = lib.mkEnableOption "private Link signed cache and gated closure preparation";
    publicKey = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Provisioned Link cache public key; never a placeholder or a private key.";
    };
    pullOnlyHosts = lib.mkOption {
      type = lib.types.listOf (lib.types.enum clients);
      default = [ ];
      description = ''
        Cache clients switched to strict pull-only operation (max-jobs = 0,
        fallback = false). Other enabled clients keep the cache substituter
        and signature trust but retain their local build and fallback defaults.
      '';
    };
  };

  config.linkCache.enable = true;
  config.linkCache.publicKey = "nix-cache.nyc.finnrut.is-1:FdhxTbOxa/QzjWT/D+zv3kt+VQ6w7mujGXuU7oHm0bE=";

  config.configurations.nixos =
    lib.genAttrs clients (name: {
      module =
        { config, ... }:
        lib.mkMerge [
          {
            assertions = [
              {
                assertion = !(lib.elem name cfg.pullOnlyHosts) || cfg.enable;
                message = "linkCache.pullOnlyHosts requires linkCache.enable.";
              }
            ];
          }
          (lib.mkIf cfg.enable {
            assertions = prerequisites ++ [
              {
                assertion = !config.nix.distributedBuilds && config.nix.buildMachines == [ ];
                message = "Link cache clients must not forward builds.";
              }
              {
                assertion = config.nixpkgs.hostPlatform.system == linkSystem;
                message = "Link cache clients must match Link's native build platform.";
              }
            ];
            networking.hosts = lib.optionalAttrs validAddress { ${address} = [ fqdn ]; };
            nix.settings = {
              substituters = [ "https://${fqdn}:5050" ];
              trusted-public-keys = lib.optional validKey cfg.publicKey;
              require-sigs = true;
            };
          })
          (lib.mkIf (cfg.enable && lib.elem name cfg.pullOnlyHosts) {
            # Opt-in no-local-jobs/no-source-fallback policy; explicit output-copy required.
            nix.settings = {
              max-jobs = 0;
              fallback = false;
            };
          })
        ];
    })
    // {
      link.module =
        { config, ... }:
        lib.mkIf cfg.enable {
          assertions = prerequisites ++ [
            {
              assertion =
                config.services.nix-serve.bindAddress == "127.0.0.1"
                && config.services.nix-serve.port == 5051
                && !config.services.nix-serve.openFirewall;
              message = "Link cache backend must stay on loopback:5051 without firewall openings.";
            }
            {
              assertion = config.networking.firewall.enable && !config.networking.nftables.enable;
              message = "Link cache exact-source firewall requires the NixOS iptables backend.";
            }
            {
              assertion = !config.nix.distributedBuilds && config.nix.buildMachines == [ ];
              message = "Link must build locally, not forward builds.";
            }
          ];
          networking.hosts = lib.optionalAttrs validAddress { ${address} = [ fqdn ]; };
          age.secrets = lib.mkIf (builtins.pathExists secretFile) {
            link-nix-cache-signing-key = {
              file = secretFile;
              owner = "root";
              group = "root";
              mode = "0400";
              path = secretPath;
            };
          };
          services.nix-serve = {
            enable = true;
            bindAddress = "127.0.0.1";
            port = 5051;
            openFirewall = false;
            # Runtime string, not a Nix path: systemd loads this as a credential.
            secretKeyFile = secretPath;
          };
          systemd.services.nix-serve = {
            preStart = lib.optionalString validKey ''
              actual="$(${config.nix.package}/bin/nix --extra-experimental-features nix-command key convert-secret-to-public < "$CREDENTIALS_DIRECTORY/NIX_SECRET_KEY_FILE")"
              if [ "$actual" != ${lib.escapeShellArg cfg.publicKey} ]; then
                echo "Link cache signing credential does not match configured public key" >&2
                exit 1
              fi
            '';
            serviceConfig = {
              NoNewPrivileges = true;
              CapabilityBoundingSet = "";
              AmbientCapabilities = "";
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              PrivateDevices = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              RestrictSUIDSGID = true;
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
              ];
              MemoryMax = "1G";
              TasksMax = 128;
              CPUWeight = 20;
              IOWeight = 20;
              UMask = "0077";
            };
          };
          security.acme.certs.${fqdn} = {
            domain = fqdn;
            dnsProvider = "cloudflare";
            # Internal DNS shadows challenge subdomains; check public propagation directly.
            dnsResolver = "1.1.1.1:53";
            environmentFile = "/run/agenix/cloudflare-acme-dns01";
            group = config.services.nginx.group;
          };
          systemd.services."acme-order-renew-${fqdn}".unitConfig.ConditionPathExists = [
            "/run/agenix/cloudflare-acme-dns01"
          ];
          services.nginx = {
            enable = true;
            recommendedTlsSettings = true;
            virtualHosts.${fqdn} = {
              listen = [
                {
                  addr = if validAddress then address else "127.0.0.1";
                  port = 5050;
                  ssl = true;
                  extraParameters = [ "default_server" ];
                }
              ];
              onlySSL = true;
              useACMEHost = fqdn;
              extraConfig = ''
                access_log off;
                if ($http_host !~ "^${fqdnRegex}(?::5050)?$") { return 444; }
              '';
              # These are the routes emitted by pinned nix-serve a7e046d. No logs,
              # writes, query strings or arbitrary store requests are exposed.
              locations."~ ^/(nix-cache-info|[0-9a-z]+\\.narinfo|nar/[0-9a-z]+(-[0-9a-z]+)?\\.nar)$" = {
                proxyPass = "http://127.0.0.1:5051";
                extraConfig = ''
                  ${lib.concatMapStrings (ip: "allow ${ip}/32;\n") sources}
                  deny all;
                  limit_except GET HEAD { deny all; }
                  if ($args != "") { return 404; }
                  proxy_buffering off;
                  proxy_max_temp_file_size 0;
                '';
              };
              locations."/".return = "404";
            };
          };
          networking.firewall = {
            extraCommands = ''
              while iptables -w -D nixos-fw -p tcp --dport 5050 -j ${chain} 2>/dev/null; do :; done
              iptables -w -N ${chain} 2>/dev/null || iptables -w -F ${chain}
              iptables -w -A ${chain} -i lo -s 127.0.0.0/8 -j nixos-fw-accept
              ${lib.concatMapStringsSep "\n" (
                ip: "iptables -w -A ${chain} -s ${ip}/32 -j nixos-fw-accept"
              ) sources}
              iptables -w -A ${chain} -j nixos-fw-refuse
              iptables -w -I nixos-fw 1 -p tcp --dport 5050 -j ${chain}
            '';
            extraStopCommands = ''
              while iptables -w -D nixos-fw -p tcp --dport 5050 -j ${chain} 2>/dev/null; do :; done
              iptables -w -F ${chain} 2>/dev/null || true
              iptables -w -X ${chain} 2>/dev/null || true
            '';
          };
        };
    };
}

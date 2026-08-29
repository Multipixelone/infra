{ config, ... }:
let
  hostDomain = "hosts.${config.servicePublication.sites.nyc.internalZone}";
in
{
  flake.modules.nixos.base.networking = {
    # NixOS also uses hostName + domain to add the host's FQDN to
    # /etc/hosts, with the FQDN as the canonical name.
    domain = hostDomain;
    search = [ hostDomain ];
  };
}

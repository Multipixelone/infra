{ inputs, ... }:
{
  configurations.nixos.link.module =
    { config, ... }:
    {
      # Cloudflare API token scoped to the finnrut.is zone. Needs Zone:DNS:Edit
      # plus Zone:Zone:Read — the client resolves the zone id by listing
      # GET /zones rather than pinning it.
      #
      # Must decrypt to the RAW token. The nixpkgs module loads it as a systemd
      # credential and exits 1 if the file starts with "CLOUDFLARE_API_TOKEN=",
      # which is how the pre-2025 EnvironmentFile form looked.
      age.secrets."cloudflare-ddns".file = "${inputs.secrets}/cloudflare/ddns.age";

      # Publishes link's WAN address as the AmneziaWG endpoint every peer
      # dials. wg.finnrut.is has to be a plain A record: the client looks up
      # records of type A only, and cannot POST one over an existing CNAME.
      services.cloudflare-dyndns = {
        enable = true;
        apiTokenFile = config.age.secrets."cloudflare-ddns".path;
        domains = [
          "wg.finnrut.is"
          "mc.finnrut.is"
        ];
        # Load-bearing. The Cloudflare proxy only carries HTTP over TCP, so an
        # orange-clouded record silently blackholes WireGuard on UDP 443.
        proxied = false;
        ipv4 = true;
        ipv6 = false;
        # Keep the last known-good record if IP detection fails, rather than
        # deleting the only name that reaches this network.
        deleteMissing = false;
        # frequency is left at the module default of every five minutes, which
        # bounds how long a WAN address change goes unpublished. That window,
        # not the record TTL, is what strands peers.
      };

      # The module orders itself after network.target only, which still races
      # the WAN: the public address is detected over HTTP and that fails until
      # routing is actually up.
      systemd.services.cloudflare-dyndns = {
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
      };
    };
}

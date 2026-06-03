{ inputs, ... }:
{
  configurations.nixos.link.module =
    { config, ... }:
    {
      # Token signing key required by the kavita module. Lives in nix-secrets.
      # Generate with: head -c 64 /dev/urandom | base64 --wrap=0
      age.secrets."kavita" = {
        file = "${inputs.secrets}/media/kavita.age";
        mode = "440";
        owner = "kavita";
        group = "kavita";
      };

      # Dedicated, initially-empty library dir for comics/manga/ebooks.
      # tunnel:users matches the convention used by other /srv services so the
      # owner can drop content in; add it as a library in Kavita's UI.
      systemd.tmpfiles.rules = [
        "d /srv/kavita 0775 tunnel users -"
        "d /srv/kavita/library 0775 tunnel users -"
      ];

      services.kavita = {
        enable = true;
        tokenKeyFile = config.age.secrets."kavita".path;
        settings.Port = 5000;
      };

      # The kavita module doesn't open the firewall. Opening the port matches
      # repo convention and allows LAN access; the tunnel itself reaches Kavita
      # over localhost. Exposed publicly at rpg.finnrut.is via the cloudflared
      # tunnel (ingress route configured in the Cloudflare Zero Trust dashboard).
      networking.firewall.allowedTCPPorts = [ 5000 ];
    };
}

{ inputs, ... }:
{
  configurations.nixos.link.module =
    { config, ... }:
    {
      # Soulseek daemon backing Explo's slskd download path. Explo authenticates
      # to it over its API; the existing Nicotine+ container has no API, so a
      # dedicated slskd instance is needed. Keep the Nicotine+ container stopped
      # while slskd is up to avoid two simultaneous Soulseek logins.
      age.secrets."slskd".file = "${inputs.secrets}/media/slskd.age";

      systemd.tmpfiles.rules = [
        "d /volume1/Media/ImportMusic/slskd 0775 tunnel users -"
      ];

      services.slskd = {
        enable = true;
        domain = null; # no nginx vhost (option has no default, must be set)
        # Must provide SLSKD_SLSK_USERNAME/SLSKD_SLSK_PASSWORD (Soulseek),
        # SLSKD_USERNAME/SLSKD_PASSWORD (web UI) and SLSKD_API_KEY (the "primary"
        # key Explo authenticates with) — see media/slskd.age.
        environmentFile = config.age.secrets."slskd".path;
        # Run as the tunnel login user so downloads are owned tunnel:users,
        # matching the music library and letting Explo migrate them.
        user = "tunnel";
        group = "users";
        openFirewall = true; # Soulseek listen port (not the web UI)
        settings = {
          shares.directories = [ "/volume1/Media/Music" ];
          directories.downloads = "/volume1/Media/ImportMusic/slskd";
          web.port = 5030;
        };
      };
    };
}

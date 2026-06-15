{ inputs, ... }:
{
  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      # ALL of Explo's config is declared in Nix: media/explo.age is the complete
      # .env (app settings, Plex creds, slskd key, schedules, ENRICH_TRACK_METADATA),
      # mounted read-only at Explo's default config path (/opt/explo/.env, the
      # WEB_ENV_PATH/CfgPath default — also what crond's scheduled runs read). The
      # web UI becomes view-only and PERSIST=false stops Explo writing back, so the
      # config can't drift imperatively.
      #
      # Downloads flow (set in the .env): Explo writes recommended tracks into
      # stagingDir; a beets singleton importer (modules/media/beets.nix) tags them
      # (using the MBIDs Explo embeds) and moves them into /volume1/Media/Music,
      # which Plex then indexes.
      stagingDir = "/volume1/Media/ImportMusic/Explo/"; # = DOWNLOAD_DIR in the .env
      slskdDir = "/volume1/Media/ImportMusic/slskd/"; # = SLSKD_DIR in the .env
      configDir = "/srv/explo";

      # Explo -> OpenClaw -> Telegram bridge. Explo's HTTP_RECEIVER posts a fixed
      # JSON payload on notable events (playlist created, ...); OpenClaw has no
      # generic inbound webhook (only Gmail), so this loopback shim translates the
      # payload into an `openclaw message send`. The Explo container runs
      # --network=host, so it reaches the shim at 127.0.0.1.
      bridgePort = 18790;

      # Reuse the openclaw binary that modules/link/openclaw.nix installs into
      # tunnel's home via npm; the wrapper adds nodejs so its #!node shebang
      # resolves inside the systemd sandbox (same pattern as commutecompass.nix).
      openclawWrapper = pkgs.writeShellApplication {
        name = "openclaw";
        runtimeInputs = [ pkgs.nodejs ];
        text = ''exec /home/tunnel/.npm-global/bin/openclaw "$@"'';
      };

      exploNotify = pkgs.writeShellScriptBin "explo-notify" ''
        unset PYTHONPATH PYTHONHOME PYTHONNOUSERSITE
        exec ${pkgs.python312}/bin/python3 ${./explo_notify.py} "$@"
      '';
    in
    {
      age.secrets."explo".file = "${inputs.secrets}/media/explo.age";

      networking.firewall.allowedTCPPorts = [ 7288 ]; # Explo web UI (LAN)

      systemd.tmpfiles.rules = [
        "d ${configDir} 0750 root root -"
        # Explo (root container) writes downloads here; the beets user service
        # (tunnel) moves them out. setgid (2xxx) so the per-playlist subdirs
        # Explo creates as root (Weekly-Jams/, …) inherit the `users` group;
        # combined with the container's --umask=0002 they land group-writable,
        # so tunnel (∈ users) can rename tracks out of them.
        "d /volume1/Media/ImportMusic/Explo 2775 tunnel users -"
      ];

      virtualisation.oci-containers.containers.explo = {
        image = "ghcr.io/lumepart/explo:latest";
        autoStart = true;
        # Host networking: reach slskd at 127.0.0.1:5030 and serve the web UI on
        # host :7288. The container runs as root because start.sh runs
        # `apk add --upgrade yt-dlp` on every scheduled run (needs root); PUID
        # mapping is intentionally unused. Files land root-owned but
        # world-readable, so the beets importer (tunnel) can read/move them.
        # umask 002 so root-created dirs are 0775 / files 0664 (group-writable).
        # With the setgid staging dir above, tunnel can rename tracks out of the
        # per-playlist subdirs Explo creates. (podman backend supports --umask.)
        extraOptions = [
          "--network=host"
          "--umask=0002"
        ];
        volumes = [
          # Full declarative config (decrypted agenix .env), read-only.
          "${config.age.secrets."explo".path}:/opt/explo/.env:ro"
          "${configDir}:/opt/explo/config" # playlist cache + cover art (WEB_DATA_PATH)
          "${stagingDir}:${stagingDir}" # DOWNLOAD_DIR: beets singleton-imports from here
          "${slskdDir}:${slskdDir}" # SLSKD_DIR: Explo migrates slskd downloads into staging
        ];
        environment = {
          # Only true runtime env vars here; everything else is in the .env above.
          TZ = "America/New_York"; # process timezone (Go time + crond); not read from .env
          WEB_ENV_PATH = "/opt/explo/.env"; # explicit (matches default); crond uses the default too
          # Notification sink: cleanenv reads .env first then process env, and
          # HTTP_RECEIVER isn't in the .env, so this supplies it. Points at the
          # loopback bridge below (explo-notify -> openclaw -> Telegram).
          HTTP_RECEIVER = "http://127.0.0.1:${toString bridgePort}";
        };
      };

      # Bridge service: receives Explo's webhook and relays via OpenClaw. Runs as
      # a tunnel user service so it shares the OpenClaw gateway state under
      # ~/.openclaw (the gateway itself is a tunnel user service, modules/link/
      # openclaw.nix). The Telegram chat id is reused from commutecompass's agenix
      # secret (OPENCLAW_TARGET in tokens.age) so the destination lives in one
      # place; tunnel is in the commutecompass group, so it can read the 0440 file.
      home-manager.users.tunnel.systemd.user.services.explo-notify = {
        Unit = {
          Description = "Explo -> OpenClaw -> Telegram notification bridge";
          After = [ "openclaw-gateway.service" ];
          Wants = [ "openclaw-gateway.service" ];
        };
        Service = {
          ExecStart = "${exploNotify}/bin/explo-notify";
          EnvironmentFile = config.age.secrets."commutecompass".path; # OPENCLAW_TARGET
          Environment = [
            "EXPLO_NOTIFY_PORT=${toString bridgePort}"
            "OPENCLAW_BIN=${openclawWrapper}/bin/openclaw"
          ];
          Restart = "always";
          RestartSec = "5s";
        };
        Install.WantedBy = [ "default.target" ];
      };
    };
}

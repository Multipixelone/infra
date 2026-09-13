{
  inputs,
  lib,
  rootPath,
  withSystem,
  ...
}:
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (lib.hasSuffix "-linux" system) {
      packages.openclaw-music = pkgs.python3Packages.callPackage "${rootPath}/pkgs/openclaw-music" { };
    };

  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      ledger-root = "/home/tunnel/.local/state/openclaw-music";
      staging-root = "/volume1/Media/ImportMusic/OpenClaw";
      download-root = "/volume1/Media/ImportMusic/slskd";
      batch-root = "${download-root}/openclaw";
      library-root = "/volume1/Media/Music";
      beets-dir = "/home/tunnel/.config/beets";
      beets-config = "${beets-dir}/config.yaml";
      beets-lock = "${beets-dir}/.import.lock";
      beets-cache = "/home/tunnel/.cache/openclaw-music-beets";
      slskd-url = "http://127.0.0.1:5030";
      package = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.openclaw-music
      );
      beets-plugins = inputs.beets-plugins.packages.${pkgs.stdenv.hostPlatform.system}.default;
      beets-path =
        lib.makeBinPath [
          beets-plugins
          pkgs.ffmpeg-full
          pkgs.coreutils
          pkgs.findutils
          pkgs.util-linux
        ]
        + ":/etc/profiles/per-user/tunnel/bin:/run/current-system/sw/bin";
      nonOverlapping = a: b: a != b && !(lib.hasPrefix "${a}/" b) && !(lib.hasPrefix "${b}/" a);
      openclaw-music = pkgs.writeShellApplication {
        name = "openclaw-music";
        text = ''
          # TRANSPORT_ISOLATED also relies on pinned Explo moving only transfers it queued.
          exec ${pkgs.coreutils}/bin/env -i \
            HOME=/home/tunnel PATH=${beets-path} LANG=C LC_ALL=C \
            BEETSDIR=${beets-dir} XDG_CONFIG_HOME=/home/tunnel/.config XDG_CACHE_HOME=${beets-cache} \
            OPENCLAW_MUSIC_LEDGER=${ledger-root} \
            OPENCLAW_MUSIC_STAGING=${staging-root} \
            OPENCLAW_MUSIC_DOWNLOAD_ROOT=${download-root} \
            OPENCLAW_MUSIC_MB_USER_AGENT='openclaw-music/1.0 (https://github.com/Multipixelone/infra)' \
            OPENCLAW_MUSIC_SLSKD_URL=${slskd-url} \
            OPENCLAW_MUSIC_SLSKD_SECRET=${config.age.secrets.slskd.path} \
            OPENCLAW_MUSIC_FFPROBE=${lib.getExe' pkgs.ffmpeg-full "ffprobe"} \
            OPENCLAW_MUSIC_FFMPEG=${lib.getExe' pkgs.ffmpeg-full "ffmpeg"} \
            OPENCLAW_MUSIC_TRANSPORT_ISOLATED=1 OPENCLAW_MUSIC_QUALITY_DEFAULT=lossless-preferred \
            OPENCLAW_MUSIC_LIBRARY_ROOT=${library-root} OPENCLAW_MUSIC_BEETS=${lib.getExe beets-plugins} \
            OPENCLAW_MUSIC_BEETS_CONFIG=${beets-config} OPENCLAW_MUSIC_BEETS_LOCK=${beets-lock} \
            OPENCLAW_MUSIC_BEETS_HOME=/home/tunnel OPENCLAW_MUSIC_BEETS_PATH=${beets-path} \
            OPENCLAW_MUSIC_BEETS_CACHE=${beets-cache} OPENCLAW_MUSIC_INDEX_ADAPTER=beets-mpdupdate \
            ${lib.getExe package} "$@"
        '';
      };
      worker = pkgs.writeShellScript "openclaw-music-worker" ''
        printf '%s\n' '{"schema":1}' | ${lib.getExe openclaw-music} worker
      '';
    in
    {
      assertions = [
        {
          assertion =
            nonOverlapping staging-root download-root
            && nonOverlapping staging-root library-root
            && nonOverlapping download-root library-root;
          message = "openclaw-music staging, slskd download, and library paths must not overlap";
        }
        {
          assertion = slskd-url == "http://127.0.0.1:5030";
          message = "openclaw-music slskd URL must remain loopback";
        }
        {
          assertion = lib.hasPrefix "${download-root}/" batch-root;
          message = "openclaw-music batch subtree must stay under the slskd download root";
        }
        {
          assertion = beets-lock != ledger-root && beets-lock != staging-root;
          message = "openclaw-music beets lock must not overlap worker state or staging";
        }
      ];

      systemd.tmpfiles.rules = [
        "d ${ledger-root} 0700 tunnel users -"
        "d ${staging-root} 0700 tunnel users -"
        "d ${batch-root} 0700 tunnel users -"
        "d ${beets-cache} 0700 tunnel users -"
      ];

      home-manager.users.tunnel = {
        home.packages = [ openclaw-music ];
        systemd.user = {
          services.openclaw-music-worker = {
            Unit = {
              Description = "Process one serialized OpenClaw music job";
              After = [ "network-online.target" ];
            };
            Service = {
              Type = "oneshot";
              ExecStart = worker;
              UMask = "0077";
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = "read-only";
              ReadOnlyPaths = [
                download-root
                config.age.secrets.slskd.path
              ];
              ReadWritePaths = [
                ledger-root
                staging-root
                library-root
                beets-dir
                beets-cache
              ];
              RestrictAddressFamilies = [
                "AF_UNIX"
                "AF_INET"
                "AF_INET6"
              ];
              StandardOutput = "journal";
              StandardError = "journal";
            };
          };
          timers.openclaw-music-worker = {
            Unit.Description = "Schedule serialized OpenClaw music work";
            Timer = {
              OnBootSec = "1m";
              OnUnitInactiveSec = "12s";
              Persistent = true;
            };
            Install.WantedBy = [ "timers.target" ];
          };
        };
      };
    };
}

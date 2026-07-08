{
  lib,
  inputs,
  config,
  withSystem,
  ...
}:
{
  perSystem =
    {
      pkgs,
      inputs',
      config,
      system,
      ...
    }:
    lib.optionalAttrs (lib.hasSuffix "-linux" system) (
      let
        rclone-base-opts = [
          "--progress"
          "--stats=10s"
          "--stats-one-line"
          "--delete-before"
          "--inplace"
          "--ignore-case"
          "--modify-window"
          "2s"
          "--buffer-size"
          "0"
          "--bwlimit"
          "8M"
          "--transfers"
          "1"
          "--checkers"
          "2"
        ];
      in
      {
        packages.ipod-sync-inner = pkgs.writers.writeFishBin "ipod-sync-inner" ''
          set -l rclone_args ${lib.concatStringsSep " " rclone-base-opts}
          # ignore inherited RCLONE_CONFIG (e.g. restic's agenix-protected one)
          set -lx RCLONE_CONFIG /dev/null

          function notify
            if set -q DISPLAY; or set -q WAYLAND_DISPLAY
              ${lib.getExe' pkgs.libnotify "notify-send"} $argv
            end
          end

          function fail
            echo "ipod-sync: $argv[1]" >&2
            notify -u critical -a ipod-sync "iPod sync failed" "$argv[1]"
            exit 1
          end

          if not ${lib.getExe' pkgs.util-linux "mountpoint"} -q -- "$IPOD_DIR"; or not test -d "$IPOD_DIR/.rockbox"
            fail "iPod not mounted at $IPOD_DIR"
          end

          ${lib.getExe' pkgs.systemd "systemctl"} --user start --wait transcode-music playlist-downloader; or fail "transcode/playlist services failed"

          if test -f "$IPOD_DIR/.rockbox/playback.log"; and command -q rb-scrobbler
            set -l LOG_FILE (${lib.getExe inputs'.playlist-download.packages.rb-scrob})
            if not rb-scrobbler -f "$LOG_FILE"
              echo "Warning: scrobble failed, continuing sync..." >&2
            end
          end
          echo "Syncing artwork..."
          ${lib.getExe pkgs.rclone} sync \
            "$ARTWORK_DIR/" \
            "$IPOD_DIR/.rockbox/albumart/" \
            $rclone_args; or fail "artwork sync failed"
          echo "Syncing playlists..."
          ${lib.getExe pkgs.rclone} sync \
            "$PLAYLIST_DIR/.ipod/" \
            "$IPOD_DIR/Playlists/" \
            $rclone_args; or fail "playlist sync failed"
          echo "Syncing music..."
          ${lib.getExe pkgs.rclone} sync \
            "$TRANSCODED_MUSIC/" \
            "$IPOD_DIR/" \
            $rclone_args; or fail "music sync failed"
          echo "Flush write cache..."
          sync "$IPOD_DIR"
          notify -a ipod-sync "iPod sync complete"
          echo "All music copied!"
        '';
        packages.ipod-sync = pkgs.writeShellScriptBin "ipod-sync" ''
          lock_dir="''${XDG_RUNTIME_DIR:-/tmp}"
          ${lib.getExe' pkgs.util-linux "flock"} -nE 99 "$lock_dir/ipod-sync.lock" \
            ${lib.getExe config.packages.ipod-sync-inner} "$@"
          status=$?
          if [ "$status" -eq 99 ]; then
            echo "ipod-sync: already running" >&2
            exit 1
          fi
          exit "$status"
        '';
      }
    );

  flake.modules.homeManager.media =
    hmArgs@{
      pkgs,
      ...
    }:
    let
      playlist-download = inputs.playlist-download.packages.${pkgs.stdenv.hostPlatform.system};
      # wrap secret into lastfm scrobbler
      lastfm-wrapped = pkgs.writeShellScriptBin "rb-scrobbler" ''
        set -o allexport
        source ${hmArgs.config.age.secrets."lastfm".path}
        ${
          lib.getExe inputs.rb-scrobbler.packages.${pkgs.stdenv.hostPlatform.system}.default
        } -n "keep" -o -4 $@
      '';

      # TODO do this. literally any other way. this is dependent on so many external things its not even funny
      rockbox-database = pkgs.writeShellApplication {
        name = "rockbox-database";
        runtimeInputs = [
          pkgs.podman
        ];
        text = ''
          DAP_ROOT_FOLDER=/volume1/Media/TranscodedMusic
          SRC_FOLDER_PATH=/home/tunnel/Documents/Git/rockbox-docker/rockbox-git
          podman run --rm -v "$SRC_FOLDER_PATH":/usr/src/rockbox -v "$DAP_ROOT_FOLDER":/mnt/dap --name rockboxdatabaserool$((RANDOM)) localhost/rockbox:latest /usr/src/rockbox/databasetool.sh
        '';
      };

      ipod-sync = withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.ipod-sync);
    in
    {
      age.secrets = {
        "plex" = {
          file = "${inputs.secrets}/media/plextoken.age";
          mode = "400";
        };
        "lastfm" = {
          file = "${inputs.secrets}/media/qtscrob.age";
          mode = "400";
        };
      };
      home.sessionVariables = {
        IPOD_DIR = "/run/media/${config.flake.meta.owner.username}/FINNR_S IPO";
      };
      home.packages = [
        playlist-download.default
        playlist-download.rb-scrob

        lastfm-wrapped
        rockbox-database

        ipod-sync
      ];
    };
}

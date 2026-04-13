{
  lib,
  inputs,
  config,
  ...
}:
{
  flake.modules.homeManager.gui =
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
      rclone-config = pkgs.writeText "rclone-ipod.conf" ''
        [ipod_disk]
        type = local
        nounc = true

        [ipod_hasher]
        type = hasher
        remote = ipod_disk:${hmArgs.config.home.sessionVariables.IPOD_DIR}
        db_path = ${hmArgs.config.xdg.cacheHome}/rclone/ipod_hasher.db
        max_age = off
      '';
      rclone-wrapped = pkgs.writeShellScriptBin "rclone" ''
        ${lib.getExe pkgs.rclone} --config="${rclone-config}" "$@"
      '';
      rclone-base-opts = [
        "--progress"
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
      ipod-sync = pkgs.writeFishBin "ipod-sync" ''
        set -l rclone_args ${lib.concatStringsSep " " rclone-base-opts}

        if test -d "$IPOD_DIR"
          ${lib.getExe' pkgs.systemd "systemctl"} --user start --wait transcode-music playlist-downloader
          if test -f "$IPOD_DIR/.rockbox/playback.log"
            set LOG_FILE (${lib.getExe playlist-download.rb-scrob})
            ${lib.getExe lastfm-wrapped} -f "$LOG_FILE"
          end
          ${lib.getExe rclone-wrapped} sync \
            "${hmArgs.config.home.sessionVariables.ARTWORK_DIR}/" \
            "$IPOD_DIR/.rockbox/albumart/" \
            $rclone_args
          ${lib.getExe rclone-wrapped} sync \
            "$PLAYLIST_DIR/.ipod/" \
            "$IPOD_DIR/Playlists/" \
            $rclone_args
          echo "Syncing music..."
          ${lib.getExe rclone-wrapped} sync \
            "${hmArgs.config.home.sessionVariables.TRANSCODED_MUSIC}/" \
            "${hmArgs.config.home.sessionVariables.IPOD_DIR}/" \
            $rclone_args
          echo "Flush write cache..."
          sync "$IPOD_DIR"
          echo "All music copied!"
        end
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

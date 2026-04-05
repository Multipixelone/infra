{ lib, ... }:
{
  configurations.nixos.zelda.module =
    { pkgs, ... }:
    let
      sunpaper = pkgs.sunpaper.overrideAttrs (oldAttrs: {
        postPatch = ''
          substituteInPlace sunpaper.sh \
            --replace-fail "sunwait" "${lib.getExe pkgs.sunwait}" \
            --replace-fail "setwallpaper" "${lib.getExe' pkgs.wallutils "setwallpaper"}" \
            --replace-fail '$HOME/sunpaper/images/Corporate-Synergy' "$out/share/sunpaper/images/Lakeside" \
            --replace-fail '/usr/share' '/etc' \
            --replace-fail "swww" "awww"
        '';
        buildInputs = oldAttrs.buildInputs ++ [
          pkgs.awww
          pkgs.bc
        ];
      });
    in
    {
      home-manager.users.tunnel =
        { config, ... }:
        {
          home.sessionVariables = lib.mkForce {
            MUSIC_DIR = "${config.xdg.userDirs.music}/Library";
            TRANSCODED_MUSIC = "${config.xdg.userDirs.music}/Library";
            ARTWORK_DIR = "${config.xdg.userDirs.music}/RockboxCover";
            MOPIDY_PLAYLISTS = "/home/tunnel/.local/share/mopidy/m3u";
            IPOD_DIR = "/run/media/tunnel/FINNR_S IPO";
            PLAYLIST_DIR = "/home/tunnel/Music/Playlists";
          };
          xdg.configFile."sunpaper/config".text = ''
            latitude="40.680271N"
            longitude="73.944893W"

            awww_enable="true"
            awww_fps="240"
            awww_step="30"
          '';
          systemd.user = {
            timers.sunpaper = {
              Install.WantedBy = [ "timers.target" ];
              Timer = {
                OnCalendar = "*:0/1";
              };
            };
            services.sunpaper = {
              Unit.Description = "automatic wallpaper set based on sun";
              Install.WantedBy = [ "graphical-session.target" ];
              Service = {
                ExecStart = lib.getExe sunpaper;
              };
            };
            services.sunpaper-cache = {
              Unit.Description = "clear sunpaper cache on startup";
              Install.WantedBy = [ "graphical-session.target" ];
              Service = {
                Type = "oneshot";
                RemainAfterExit = "no";
                ExecStart = "${lib.getExe sunpaper} -c";
              };
            };
          };
          home.packages = [
            sunpaper
          ];
        };
    };
}

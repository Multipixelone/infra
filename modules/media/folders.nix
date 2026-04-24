{
  flake.modules.homeManager.media = hmArgs: {
    home.sessionVariables = {
      PLAYLIST_DIR = "${hmArgs.config.xdg.userDirs.music}/Playlists";
      MUSIC_DIR = "${hmArgs.config.xdg.userDirs.music}/Library";
    };
  };
}

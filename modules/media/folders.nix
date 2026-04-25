{
  flake.modules.homeManager.media = hmArgs: {
    home.sessionVariables = {
      PLAYLIST_DIR = hmArgs.config.infra.media.paths.playlistDir;
      MUSIC_DIR = hmArgs.config.infra.media.paths.libraryDir;
    };
  };
}

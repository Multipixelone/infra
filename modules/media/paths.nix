{ lib, ... }:
{
  flake.modules.homeManager.base = hmArgs: {
    options.infra.media.paths = {
      musicBase = lib.mkOption {
        type = lib.types.str;
        default = hmArgs.config.xdg.userDirs.music;
        description = "Base directory for music (defaults to XDG music dir).";
      };
      libraryDir = lib.mkOption {
        type = lib.types.str;
        default = "${hmArgs.config.infra.media.paths.musicBase}/Library";
        description = "Music library directory.";
      };
      playlistDir = lib.mkOption {
        type = lib.types.str;
        default = "${hmArgs.config.infra.media.paths.musicBase}/Playlists";
        description = "Playlists directory.";
      };
    };
    config.home.sessionVariables = {
      MUSIC_DIR = lib.mkDefault hmArgs.config.infra.media.paths.libraryDir;
      PLAYLIST_DIR = lib.mkDefault hmArgs.config.infra.media.paths.playlistDir;
    };
  };
}

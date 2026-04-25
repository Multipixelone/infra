{
  inputs,
  ...
}:
{
  flake.modules.homeManager.gui = hmArgs: {
    age.secrets."scribblepw".file = "${inputs.secrets}/media/lastfmpw.age";
    services = {
      mpd-mpris.enable = true;
      mpd = {
        enable = true;
        playlistDirectory = "${hmArgs.config.infra.media.paths.playlistDir}/.mpd";
        musicDirectory = hmArgs.config.infra.media.paths.libraryDir;
        extraConfig = ''
          audio_output {
             type   "fifo"
             name   "my_fifo"
             path   "/tmp/mpd.fifo"
             format "44100:16:2"
          }
          audio_output {
            type "pipewire"
            name "PipeWire Output"
          }
        '';
      };
      mpdscribble = {
        enable = true;
        endpoints."last.fm" = {
          username = "Tunnelmaker";
          passwordFile = hmArgs.config.age.secrets."scribblepw".path;
        };
      };
    };
  };
}

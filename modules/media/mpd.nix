{
  inputs,
  ...
}:
{
  flake.modules.homeManager.gui =
    hmArgs@{ pkgs, ... }:
    {
      age.secrets."scribblepw".file = "${inputs.secrets}/media/lastfmpw.age";
      home.packages = [
        pkgs.mpc
      ];
      services = {
        mpd-mpris.enable = true;
        mpd = {
          enable = true;
          network.listenAddress = "any";
          playlistDirectory = "${hmArgs.config.infra.media.paths.playlistDir}/.mpd";
          musicDirectory = hmArgs.config.infra.media.paths.libraryDir;
          extraConfig = ''
            replaygain "auto"
            replaygain_preamp "-6.0"
            replaygain_missing_preamp "-6.0"
            replaygain_limit "yes"

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
            audio_output {
              type   "fifo"
              name   "snapserver"
              path   "/run/snapserver/mpd-fifo"
              format "44100:16:2"
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

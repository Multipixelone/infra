{
  lib,
  inputs,
  ...
}:
{
  flake-file.inputs = {
    bgutil-ytdlp-pot-provider = {
      url = "github:Brainicism/bgutil-ytdlp-pot-provider";
      flake = false;
    };

    yt-dlp-YTNSigDeno = {
      url = "github:bashonly/yt-dlp-YTNSigDeno";
      flake = false;
    };
  };
  flake.modules.homeManager.gui =
    hmArgs@{ pkgs, ... }:
    let
      bgutil-version =
        (builtins.fromJSON (builtins.readFile "${inputs.bgutil-ytdlp-pot-provider}/server/package.json"))
        .version;
    in
    {
      age.secrets."yt-dlp" = {
        file = "${inputs.secrets}/media/ytdlp.age";
        # yt-dlp needs write access to cookie file for some reason?
        mode = "600";
      };
      xdg.configFile = {
        # plugin to connect to docker container
        "yt-dlp/plugins/bgutil-ytdlp-pot-provider".source = inputs.bgutil-ytdlp-pot-provider + "/plugin";
        # plugin to allow yt-dlp to solve with deno
        "yt-dlp/plugins/yt-dlp-deno".source = inputs.yt-dlp-YTNSigDeno;
      };
      virtualisation.quadlet.containers.bgutil-provider = {
        autoStart = true;
        serviceConfig = {
          RestartSec = "10";
          Restart = "always";
        };
        containerConfig = {
          image = "brainicism/bgutil-ytdlp-pot-provider:${bgutil-version}";
          publishPorts = [ "127.0.0.1:4416:4416" ];
        };
      };
      programs = {
        aria2.enable = true;
        yt-dlp = {
          enable = true;
          package = pkgs.yt-dlp.overrideAttrs (prev: {
            propagatedBuildInputs = (prev.propagatedBuildInputs or [ ]) ++ [ pkgs.deno ];
          });
          settings = {
            embed-thumbnail = false;
            embed-metadata = true;
            embed-chapters = true;
            embed-subs = true;
            sponsorblock-mark = "all";
            sponsorblock-remove = "sponsor";
            downloader = lib.getExe hmArgs.config.programs.aria2.package;
            downloader-args = "aria2c:'-c -x8 -s8 -k1M'";
            # cookies = config.age.secrets."yt-dlp".path;
            extractor-args = "youtube:deno_no_jitless";
          };
        };
      };
    };
}

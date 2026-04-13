{
  lib,
  withSystem,
  rootPath,
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    {
      packages = {
        lossywav = pkgs.callPackage "${rootPath}/pkgs/lossywav" { };
        beets-lossyflac = pkgs.writeFishBin "beets-lossyflac" ''
          set query $argv[1]

          beet modify -awm $query format=lossyFLAC
          beet convert -y -a -f lossyflac -k -d ~/tmpTranscoded $query
          # not entirely sure why i have to run it twice, but it only works the second time for some reason.
          beet convert -y -a -f lossyflac -k -d ~/tmpTranscoded $query
        '';
        # lossyflac converter for super-duper transparent lossy archival
        convert-lossyflac =
          let
            ffmpeg = lib.getExe pkgs.ffmpeg-full;
            lossywav = withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.lossywav);
          in
          pkgs.writeFishBin "convert-lossyflac" ''
            set input_file $argv[1]
            set output_file $argv[2]

            ${ffmpeg} -i $input_file -f wav - | ${lossywav}/bin/lossywav - --quality extreme --stdout | ${ffmpeg} -i pipe: -blocksize 512 -compression_level 12 -sample_fmt s16 -ar 44100 -y -acodec flac $output_file
          '';
      };
    };

  flake.modules.homeManager.base =
    { pkgs, ... }:
    let
      beets-lossyflac = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.beets-lossyflac
      );
      convert-lossyflac = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.convert-lossyflac
      );
    in
    {
      home.packages = [
        beets-lossyflac
        convert-lossyflac
      ];
    };
}

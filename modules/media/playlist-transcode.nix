{
  withSystem,
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.playlist-transcode =
        let
          ffmpeg = lib.getExe pkgs.ffmpeg-full;
          convert-mpc = withSystem pkgs.stdenv.hostPlatform.system (
            psArgs: psArgs.config.packages.convert-mpc
          );
          mkdir = lib.getExe' pkgs.coreutils "mkdir";
          basename = lib.getExe' pkgs.coreutils "basename";
          rm = lib.getExe' pkgs.coreutils "rm";
          inherit (pkgs) lib;
        in
        pkgs.writers.writeFishBin "playlist-transcode" ''
          # playlist-transcode: transcode all tracks in an m3u playlist

          argparse 'f/format=' -- $argv
          or begin
              echo "Usage: playlist-transcode [-f opus|mpc] <playlist.m3u> <output-dir>"
              exit 1
          end

          set format $_flag_format
          if test -z "$format"
              set format opus
          end

          if not string match -qr '^(opus|mpc)$' "$format"
              echo "Error: unsupported format '$format'. Use 'opus' or 'mpc'."
              exit 1
          end

          if test (count $argv) -lt 2
              echo "Usage: playlist-transcode [-f opus|mpc] <playlist.m3u> <output-dir>"
              exit 1
          end

          set playlist $argv[1]
          set outdir $argv[2]

          if not test -f "$playlist"
            echo "Error: playlist '$playlist' not found"
            exit 1
          end

          ${mkdir} -p "$outdir"

          set total 0
          set done 0
          set failed 0

          # count tracks (skip comments and blank lines)
          for line in (cat "$playlist")
            if test -z "$line"; or string match -q '#*' "$line"
              continue
            end
            set total (math $total + 1)
          end

          echo "Transcoding $total tracks to $format in $outdir"

          for line in (cat "$playlist")
            if test -z "$line"; or string match -q '#*' "$line"
              continue
            end

            set infile "$line"

            if not test -f "$infile"
              echo "SKIP (not found): $infile"
              set failed (math $failed + 1)
              continue
            end

            # derive output filename: strip extension, add .$format
            set bname (${basename} "$infile")
            set stem (string replace -r '\.[^.]+$' "" "$bname")
            set outfile "$outdir/$stem.$format"

            if test -f "$outfile"
              echo "SKIP (exists): $outfile"
              set done (math $done + 1)
              continue
            end

            set done (math $done + 1)
            echo "[$done/$total] $bname"

            if test "$format" = "opus"
              ${ffmpeg} -hide_banner -loglevel warning -i "$infile" \
                -vn -map_metadata 0 -map 0:a \
                -codec:a libopus -b:a 96k -vbr on \
                "$outfile"
            else
              ${convert-mpc}/bin/convert-mpc "$infile" "$outfile"
            end

            if test $status -ne 0
              echo "FAIL: $infile"
              set failed (math $failed + 1)
              ${rm} -f "$outfile"
            end
          end

          echo "Done: "(math $done - $failed)" transcoded, $failed failed out of $total"
        '';
    };

  flake.modules.homeManager.media =
    { pkgs, ... }:
    let
      playlist-transcode = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.playlist-transcode
      );
    in
    {
      home.packages = [ playlist-transcode ];
    };
}

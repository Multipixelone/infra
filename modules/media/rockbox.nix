{
  lib,
  withSystem,
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.rb-albumart =
        let
          hr = "${lib.getExe pkgs.hr} ━";
        in
        pkgs.writers.writeFishBin "rb-albumart" ''
          function rockbox_art_converter
              set -l art_size "250x250"

              if test (count $argv) -ne 1
                  echo "Usage: $0 /path/to/your/music/library"
                  return 1
              end

              set -l music_dir $argv[1]

              if not test -d "$music_dir"
                  echo "Error: Directory '$music_dir' not found."
                  return 1
              end

              find "$music_dir" -type f \( -iname \*.jpg -o -iname \*.jpeg -o -iname \*.png -o -iname \*.gif -o -iname \*.bmp \) | while read -l image_file
                  set -l image_dir (dirname "$image_file")
                  # ${hr}
                  echo "Found image: $image_file"

                  set -l music_file (find "$image_dir" -maxdepth 1 -type f \( -iname \*.mp3 -o -iname \*.flac -o -iname \*.m4a \) -print -quit)

                  if test -z "$music_file"
                      echo "Warning: No music file found in '$image_dir'. Skipping."
                      continue
                  end

                  set -l artist (${lib.getExe' pkgs.ffmpeg-headless "ffprobe"} -v error -show_entries format_tags=album_artist -of default=noprint_wrappers=1:nokey=1 "$music_file")
                  set -l album (${lib.getExe' pkgs.ffmpeg-headless "ffprobe"} -v error -show_entries format_tags=album -of default=noprint_wrappers=1:nokey=1 "$music_file")

                  # Fallback if albumartist not set
                  if test -z "$artist"; set -l artist (${lib.getExe' pkgs.ffmpeg-headless "ffprobe"} -v error -show_entries format_tags=artist -of default=noprint_wrappers=1:nokey=1 "$music_file"); end

                  if test -z "$artist"; set artist "Unknown Artist"; end
                  if test -z "$album"; set album "Unknown Album"; end

                  # Clean up artist and album for a valid filename (remove slashes, etc.).
                  set -l underscores_artist (string replace -r '[/\\:\*\?\<\>|]' '_' -- $artist)
                  set -l underscores_album (string replace -r '[/\\:\*\?\<\>|]' '_' -- $album)

                  # Fix quotes (double to single)
                  set -l clean_artist (string replace -r '[\"]' '\''' -- $underscores_artist)
                  set -l clean_album (string replace -r '[\"]' '\''' -- $underscores_album)

                  set -l new_filename "$clean_artist-$clean_album.bmp"
                  set -l output_path "$ARTWORK_DIR/$new_filename"

                  echo "Converting to: $output_path"

                  # Check if the output file already exists
                  if test -f "$output_path"
                      echo "Skipping conversion: '$output_path' already exists."
                      continue
                  end

                  ${lib.getExe' pkgs.imagemagick "magick"} "$image_file" -background white -flatten -resize $art_size -interlace none +profile '*' -define bmp:subtype=RGB565 -compress None BMP3:"$output_path"

                  if test $status -eq 0
                      # echo "Successfully converted."
                  else
                      echo "Error: Image conversion failed for '$image_file'."
                  end
              end

          end

          rockbox_art_converter $argv
        '';
    };

  flake.modules.homeManager.media =
    { pkgs, ... }:
    let
      rb-albumart = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.rb-albumart
      );
    in
    {
      home.packages = [
        rb-albumart
      ];
      home.sessionVariables = {
        ARTWORK_DIR = "/volume1/Media/RockboxCover";
      };
    };
}

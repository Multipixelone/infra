{
  inputs,
  lib,
  withSystem,
  rootPath,
  ...
}:
{
  perSystem =
    { system, pkgs, ... }:
    {
      packages.musepack =
        inputs.nixpkgs-stable.legacyPackages.${system}.callPackage "${rootPath}/pkgs/musepack"
          { };
      packages.convert-mpc =
        let
          ffmpeg = lib.getExe pkgs.ffmpeg-full;
          # i don't know why I have to build this with nixpkgs-stable, but I will neex to fix it eventually
          musepack = withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.musepack);
        in
        pkgs.writers.writeFishBin "convert-mpc" ''
          # Check for correct number of arguments
          if test (count $argv) -ne 2
              echo "Usage: convert-mpc <input_file> <output_file.mpc>" >&2
              return 1
          end

          set input_file $argv[1]
          set output_file $argv[2]

          # --- Processing and Encoding ---
          set needs_conversion 1
          set temp_file ""
          set file_to_encode "$input_file"

          if test $needs_conversion -eq 1
              echo "Preprocessing necessary. Creating a temporary WAV file..."
              set temp_file (mktemp --suffix=.wav)
              set target_sample_rate 48000

              echo "Converting to temporary WAV: 16-bit, $target_sample_rate Hz, stereo..."
              # Use ffmpeg to create a standard, compatible WAV file
              if ${ffmpeg} -i "$input_file" -ac 2 -ar $target_sample_rate -c:a pcm_s16le -map_metadata -1 -y "$temp_file" >/dev/null 2>&1
                  set file_to_encode "$temp_file"
              else
                  echo "Error: Failed to convert the audio file with ffmpeg." >&2
                  rm -f "$temp_file"
                  return 1
              end
          else
              echo "Input file is already compatible with mpcenc."
          end

          set -l artist_tag (${lib.getExe' pkgs.ffmpeg-headless "ffprobe"} -v error -show_entries format_tags=artist -of default=noprint_wrappers=1:nokey=1 "$input_file")
          set -l album_artist_tag (${lib.getExe' pkgs.ffmpeg-headless "ffprobe"} -v error -show_entries format_tags=album_artist -of default=noprint_wrappers=1:nokey=1 "$input_file")
          set -l title_tag  (${lib.getExe' pkgs.ffmpeg-headless "ffprobe"} -v error -show_entries format_tags=title -of default=noprint_wrappers=1:nokey=1 "$input_file")
          set -l album_tag  (${lib.getExe' pkgs.ffmpeg-headless "ffprobe"} -v error -show_entries format_tags=album -of default=noprint_wrappers=1:nokey=1 "$input_file")
          set -l genre_tag  (${lib.getExe' pkgs.ffmpeg-headless "ffprobe"} -v error -show_entries format_tags=genre -of default=noprint_wrappers=1:nokey=1 "$input_file")
          set -l date_tag   (${lib.getExe' pkgs.ffmpeg-headless "ffprobe"} -v error -show_entries format_tags=date -of default=noprint_wrappers=1:nokey=1 "$input_file")
          set -l raw_track_tag (${lib.getExe' pkgs.ffmpeg-headless "ffprobe"} -v error -show_entries format_tags=track -of default=noprint_wrappers=1:nokey=1 "$input_file")
          set -l raw_disc_tag (${lib.getExe' pkgs.ffmpeg-headless "ffprobe"} -v error -show_entries format_tags=disc -of default=noprint_wrappers=1:nokey=1 "$input_file")

          set -l year_tag  (string sub -l 4 "$date_tag") # Take first 4 chars of date for year
          set -l track_tag (string split -m 1 '/' -- $raw_track_tag)[1] # Take first part of "15/16"
          set -l disc_tag (string split -m 1 '/' -- $raw_disc_tag)[1] # Also parse disc number

          # --- Build and Execute Final Command ---
          echo "Building mpcenc command..."

          # Start with the base command and options
          set -l mpcenc_cmd ${musepack}/bin/mpcenc --overwrite --quality 5 --ape2

          if test -n "$artist_tag"; set -a mpcenc_cmd --artist "$artist_tag"; end
          if test -n "$title_tag";  set -a mpcenc_cmd --title "$title_tag"; end
          if test -n "$album_tag";  set -a mpcenc_cmd --album "$album_tag"; end
          if test -n "$year_tag";   set -a mpcenc_cmd --year "$year_tag"; end
          if test -n "$track_tag";  set -a mpcenc_cmd --track "$track_tag"; end
          if test -n "$genre_tag";  set -a mpcenc_cmd --genre "$genre_tag"; end

          if test -n "$album_artist_tag"; set -a mpcenc_cmd --tag "Album Artist=$album_artist_tag"; end

          set -a mpcenc_cmd "$file_to_encode" "$output_file"

          echo "Encoding with the following command:"
          echo "  $mpcenc_cmd"

          echo "Encoding $file_to_encode to Musepack..."
          if $mpcenc_cmd
              echo "Successfully created '$output_file'"
              echo "Adding replaygain information"
              ${musepack}/bin/mpcgain $output_file
          else
              echo "Error: mpcenc failed to encode the file." >&2
              if test -n "$temp_file"
                  rm -f "$temp_file"
              end
              return 1
          end

          # Cleanup temporary file
          if test -n "$temp_file"
              rm -f "$temp_file"
              echo "Removed temporary file."
          end

          return 0
        '';
    };

  flake.modules.homeManager.media =
    { pkgs, ... }:
    let
      convert-mpc = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.convert-mpc
      );
    in
    {
      home.packages = [ convert-mpc ];
    };
}

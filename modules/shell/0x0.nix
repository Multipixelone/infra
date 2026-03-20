{ withSystem, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.upload-script = pkgs.writeShellApplication {
        name = "0x0";
        runtimeInputs = with pkgs; [
          curl
          coreutils
          wl-clipboard
          libnotify
        ];
        text = ''
          TEMP_UPLOAD=0
          LITTER_TIME="72h"

          usage() {
            printf 'usage: 0x0 [-t [1h|12h|24h|72h]] <file>...\n' >&2
            printf '  -t    force upload to litterbox (temporary); default duration 72h\n' >&2
            printf '  files >100MB are automatically sent to litterbox\n' >&2
          }

          while [ $# -gt 0 ]; do
            case "$1" in
              -t)
                TEMP_UPLOAD=1
                case "''${2-}" in
                  1h|12h|24h|72h) LITTER_TIME="$2"; shift ;;
                esac
                shift
                ;;
              -h|--help) usage; exit 0 ;;
              --) shift; break ;;
              -*) printf 'unknown flag: %s\n' "$1" >&2; usage; exit 1 ;;
              *) break ;;
            esac
          done

          file_upload() {
            local file="$1"
            local size
            size=$(stat -c%s "''${file}")
            local url

            if [ "''${TEMP_UPLOAD}" = "1" ] || [ "''${size}" -gt 104857600 ]; then
              printf 'uploading "%s" to litterbox (%s)...\n' "''${file}" "''${LITTER_TIME}" >&2
              if ! url=$(curl -s -f \
                -F "reqtype=fileupload" \
                -F "time=''${LITTER_TIME}" \
                -F "fileToUpload=@''${file}" \
                "https://litterbox.catbox.moe/resources/internals/api.php"); then
                printf 'upload failed for "%s"\n' "''${file}" >&2
                return 1
              fi
            else
              printf 'uploading "%s" to catbox...\n' "''${file}" >&2
              if ! url=$(curl -s -f \
                -F "reqtype=fileupload" \
                -F "fileToUpload=@''${file}" \
                "https://catbox.moe/user/api.php"); then
                printf 'upload failed for "%s"\n' "''${file}" >&2
                return 1
              fi
            fi

            printf '%s\n' "''${url}"
            if [ -n "''${WAYLAND_DISPLAY+x}" ]; then
              wl-copy "''${url}"
              notify-send "''${file} uploaded" "''${url}"
            fi
            printf '\n%s\n\t%s\n\t\t%s\n' "$(date)" "''${file}" "''${url}" >> ~/.config/0x0.history
          }

          for file in "''${@}"; do
            file_upload "''${file}"
          done
        '';
      };
    };
  flake.modules.homeManager.base =
    { pkgs, ... }:
    let
      upload-script = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.upload-script
      );
    in
    {
      home.packages = [
        upload-script
      ];
    };

}

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
          file_upload() {
            local file="$1"
            printf 'uploading "%s"...\n' "''${file}" >&2
            local url
            if ! url=$(curl -s -f -F "reqtype=fileupload" -F "fileToUpload=@''${file}" "https://catbox.moe/user/api.php"); then
              printf 'upload failed for "%s"\n' "''${file}" >&2
              return 1
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

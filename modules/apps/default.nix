{
  nixpkgs.config.allowUnfreePackages = [ "objectbox-linux" ];
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    let
      moonlight-hdr = pkgs.writeShellScriptBin "moonlight-hdr" ''
        export ENABLE_HDR_WSI=1
        export QT_QPA_PLATFORM=wayland
        export SDL_VIDEODRIVER=wayland
        exec ${pkgs.gamescope}/bin/gamescope \
          --hdr-enabled --hdr-sdr-content-nits 203 \
          --backend wayland --expose-wayland \
          --immediate-flips --rt -f -- \
          ${pkgs.moonlight-qt}/bin/moonlight-qt "$@"
      '';
    in
    {
      home.packages = with pkgs; [
        moonlight-qt
        moonlight-hdr
        waypipe
        filezilla
        # bluebubbles
      ];
    };
}

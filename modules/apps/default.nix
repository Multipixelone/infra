{
  nixpkgs.config.allowUnfreePackages = [ "objectbox-linux" ];
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    {
      # HDR re-enable: wrap moonlight-qt in gamescope to get an HDR client.
      # Define `moonlight-hdr` in a let-binding via pkgs.writeShellScriptBin
      # invoking `gamescope --hdr-enabled --hdr-sdr-content-nits 203 ...` around
      # `moonlight-qt`, then add it to home.packages below.
      home.packages = with pkgs; [
        moonlight-qt
        waypipe
        filezilla
        # bluebubbles
      ];
    };
}

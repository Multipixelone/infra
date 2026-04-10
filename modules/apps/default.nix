{
  nixpkgs.config.allowUnfreePackages = [ "objectbox-linux" ];
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    {
      home.packages = with pkgs; [
        moonlight-qt
        waypipe
        filezilla
        # bluebubbles
      ];
    };
}

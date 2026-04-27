{ inputs, ... }:
{
  flake-file.inputs.nixpkgs-mine.url = "github:Multipixelone/nixpkgs/init-soundshow";

  nixpkgs.config.allowUnfreePackages = [ "soundshow" ];
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    let
      nixpkgs-mine = import inputs.nixpkgs-mine {
        system = pkgs.stdenv.hostPlatform.system;
        config.allowUnfree = true;
      };
    in
    {
      home.packages = with pkgs; [
        mediainfo
        nixpkgs-mine.soundshow
        blanket
      ];
    };
}

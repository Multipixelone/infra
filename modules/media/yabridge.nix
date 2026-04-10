{
  rootPath,
  withSystem,
  ...
}:
{
  nixpkgs.config.allowUnfreePackages = [ "reaper" ];
  perSystem =
    { pkgs, ... }:
    {
      packages.izotope = pkgs.callPackage "${rootPath}/pkgs/izotope" { };
    };
  flake.modules.homeManager.gaming =
    { pkgs, ... }:
    let
      izotope = withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.izotope);
    in
    {
      home.packages = with pkgs; [
        reaper
        yabridge
        yabridgectl
        (izotope.override { location = "/home/tunnel/.izotope11"; })
      ];
    };
}

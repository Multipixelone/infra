{
  rootPath,
  withSystem,
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.asl-anki = pkgs.python3Packages.callPackage "${rootPath}/pkgs/asl-anki" {
        inherit (pkgs) ffmpeg gifski;
      };
    };

  flake.modules.homeManager.base =
    { pkgs, ... }:
    let
      asl-anki = withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.asl-anki);
    in
    {
      home.packages = [ asl-anki ];
    };
}

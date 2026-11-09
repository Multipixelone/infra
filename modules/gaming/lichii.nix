{
  lib,
  rootPath,
  inputs,
  withSystem,
  ...
}:
{
  flake-file.inputs.lichii = {
    url = "github:zortos293/Lichii/nx2";
    flake = false;
  };

  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.lichii = pkgs.callPackage "${rootPath}/pkgs/lichii" {
        src = inputs.lichii;
      };
    };

  flake.modules.homeManager.gaming =
    { pkgs, ... }:
    {
      home.packages = [
        (withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.lichii))
      ];
    };
}

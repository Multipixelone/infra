{
  lib,
  rootPath,
  inputs,
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
}

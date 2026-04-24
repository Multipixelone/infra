{
  inputs,
  ...
}:
{
  flake-file.inputs.khinsider = {
    url = "github:Multipixelone/khinsider/nix-build";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.flake-utils.follows = "flake-utils";
  };
  flake.modules.homeManager.media =
    { pkgs, ... }:
    {
      home.packages = [
        inputs.khinsider.packages.${pkgs.stdenv.hostPlatform.system}.default
      ];
    };
}

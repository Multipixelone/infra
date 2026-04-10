{ inputs, ... }:
{
  flake-file.inputs.wrappers = {
    url = "github:BirdeeHub/nix-wrapper-modules";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  imports = [ inputs.wrappers.flakeModules.wrappers ];
  perSystem = {
    wrappers.control_type = "build";
  };
}

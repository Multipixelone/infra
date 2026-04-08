{ inputs, lib, ... }:
{
  flake.modules.nixos.base = {
    nix =
      let
        flakeInputs = lib.filterAttrs (_: v: lib.isType "flake" v) inputs;
      in
      {
        registry = lib.mapAttrs (_: v: { flake = v; }) flakeInputs;
        nixPath = [
          "nixpkgs=${inputs.nixpkgs}"
        ];
      };
  };

  flake.modules.homeManager.base = {
    nix.nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];
  };
}

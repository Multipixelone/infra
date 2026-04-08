{ inputs, lib, ... }:
{
  flake.modules.nixos.base = {
    nix =
      let
        flakeInputs = lib.filterAttrs (_: v: lib.isType "flake" v) inputs;
      in
      {
        channel.enable = false;
        registry = lib.mapAttrs (_: v: { flake = v; }) flakeInputs;
        nixPath = [
          "nixpkgs=${inputs.nixpkgs}"
        ];
      };
  };
}

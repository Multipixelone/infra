{ lib, ... }:
{
  flake-file = {
    description = "Multipixelone (Finn)'s nix + HomeManager config";

    nixConfig = {
      abort-on-warn = true;
      extra-experimental-features = [
        "pipe-operators"
      ];
      allow-import-from-derivation = false;
    };

    inputs = {
      nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

      # All four systems (incl. aarch64-darwin) so flake-utils-based inputs that
      # `follows = "systems"` (e.g. agenix) expose darwin packages. NOTE: this is
      # the *input*; the flake-parts perSystem list (modules/systems.nix) stays
      # Linux-only so our own perSystem outputs don't eval on darwin.
      systems.url = "github:nix-systems/default";

      flake-compat.url = "github:edolstra/flake-compat";

      flake-utils = {
        url = "github:numtide/flake-utils";
        inputs.systems.follows = "systems";
      };

      flake-parts = {
        url = "github:hercules-ci/flake-parts";
        inputs.nixpkgs-lib.follows = "nixpkgs";
      };

      flake-file.url = "github:vic/flake-file";
      import-tree.url = lib.mkDefault "github:vic/import-tree";

      # nixos-wsl = {
      #   url = "github:nix-community/NixOS-WSL/main";
      #   inputs = {
      #     nixpkgs.follows = "nixpkgs";
      #     flake-compat.follows = "flake-compat";
      #   };
      # };

      home-manager = {
        url = "github:nix-community/home-manager/master";
        inputs.nixpkgs.follows = "nixpkgs";
      };
    };
  };
}

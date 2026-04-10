{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  flake-file.inputs.treefmt-nix = {
    url = "github:numtide/treefmt-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  perSystem = {
    treefmt = {
      projectRootFile = "flake.nix";
      programs = {
        prettier.enable = true;
        shfmt.enable = true;
      };
      settings = {
        on-unmatched = "fatal";
        global.excludes = [
          "*.jpg"
          "*.png"
          "Justfile"
          "LICENSE"
          "*.fish"
        ];
      };
    };
    pre-commit.settings.hooks.treefmt.enable = true;
  };
}

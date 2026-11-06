{ inputs, ... }:
{
  flake-file.inputs.statix = {
    url = "github:molybdenumsoftware/statix";
    inputs = {
      flake-parts.follows = "flake-parts";
      nixpkgs.follows = "nixpkgs";
    };
  };

  nixpkgs.overlays = [ (import "${inputs.statix}/overlay.nix") ];

  perSystem = {
    treefmt.programs = {
      # These tools rewrite the same files: serialize fixes, then format last.
      deadnix = {
        enable = true;
        priority = 1;
      };

      nixf-diagnose = {
        enable = true;
        priority = 2;
        ignore = [
          "sema-unused-def-lambda-noarg-formal"
          "sema-unused-def-lambda-witharg-arg"
          "sema-unused-def-lambda-witharg-formal"
        ];
      };

      statix = {
        enable = true;
        priority = 3;
      };
      nixfmt.priority = 4;
    };
  };
}

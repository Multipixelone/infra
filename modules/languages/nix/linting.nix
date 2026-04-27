{
  flake-file.inputs.statix = {
    url = "github:molybdenumsoftware/statix";
    inputs = {
      flake-parts.follows = "flake-parts";
      nixpkgs.follows = "nixpkgs";
    };
  };

  perSystem =
    { inputs', ... }:
    {
      treefmt.programs = {
        deadnix.enable = true;

        nixf-diagnose = {
          enable = true;
          ignore = [
            "sema-unused-def-lambda-noarg-formal"
            "sema-unused-def-lambda-witharg-arg"
            "sema-unused-def-lambda-witharg-formal"
          ];
        };

        statix = {
          enable = true;
          package = inputs'.statix.packages.default;
        };
      };
    };
}

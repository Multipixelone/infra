{ inputs, ... }:
{
  flake-file.inputs.nix-index-database = {
    url = "github:nix-community/nix-index-database";
    inputs.nixpkgs.follows = "nixpkgs";
  };
  flake.modules.homeManager.base = {
    imports = [ inputs.nix-index-database.homeModules.nix-index ];
    programs = {
      nix-index.enable = true;
      nix-index-database.comma.enable = true;
    };
  };
}

{
  flake-file.inputs.nix-minecraft = {
    # The maintained nix-minecraft repository (Infinidim-Enterprises is a 404).
    url = "github:Infinidoge/nix-minecraft";
    inputs = {
      nixpkgs.follows = "nixpkgs";
      systems.follows = "systems";
      flake-compat.follows = "flake-compat";
    };
  };
}

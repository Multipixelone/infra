{
  caches = [
    {
      url = "https://prismlauncher.cachix.org";
      key = "prismlauncher.cachix.org-1:9/n/FGyABA2jLUVfY+DEp4hKds/rwO+SCOtbOkDzd+c=";
    }
    {
      url = "https://nix-gaming.cachix.org";
      key = "nix-gaming.cachix.org-1:nbjlureqMbRAxR1gJ/f3hxemL9svXaZF/Ees8vCUUs4=";
    }
  ];
  flake-file.inputs = {
    nix-gaming = {
      url = "github:fufexan/nix-gaming";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
      };
    };
  };
  nixpkgs.config.allowUnfreePackages = [
    "vintagestory"
  ];
  flake.modules.homeManager.gaming =
    { pkgs, ... }:
    {
      home.packages = [
        pkgs.prismlauncher
        pkgs.vintagestory
      ];
    };
}

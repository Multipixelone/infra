{
  caches = [
    {
      url = "https://prismlauncher.cachix.org";
      key = "prismlauncher.cachix.org-1:9/n/FGyABA2jLUVfY+DEp4hKds/rwO+SCOtbOkDzd+c=";
    }
  ];
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

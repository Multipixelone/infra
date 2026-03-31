{
  perSystem = pkgs: {
    make-shells.default.packages = [
      pkgs.bashInteractive
    ];
  };
  nixpkgs.config.allowUnfreePackages = [ "github-copilot-cli" ];
  flake.modules.homeManager.base =
    { pkgs, ... }:
    {
      home.packages = [
        pkgs.github-copilot-cli
      ];
    };
}

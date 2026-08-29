{
  nixpkgs.config.allowUnfreePackages = [ "ventoy" ];
  nixpkgs.config.permittedInsecurePackages = [ "ventoy" ];

  flake.modules.homeManager.gui =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.ventoy ];
    };
}

{
  flake-file.inputs.lanzaboote = {
    url = "github:nix-community/lanzaboote/v1.0.0";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  flake.modules.nixos.pc =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        pkgs.sbctl
      ];

      # boot.loader.systemd-boot.enable = lib.mkForce false;
      # boot.loader.limine.secureBoot.enable = true;
      # like. i cant figure out how to reset the pk on my blade. freaking weird.
      # boot.lanzaboote = {
      #   enable = false;
      #   pkiBundle = "/var/lib/sbctl";
      # };

    };
}

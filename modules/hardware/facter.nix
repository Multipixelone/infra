{ inputs, ... }:
{
  flake-file.inputs = {
    nixos-facter-modules.url = "github:numtide/nixos-facter-modules";
    nix-hardware.url = "github:NixOS/nixos-hardware/master";
  };
  flake.modules = {
    nixos.base = {
      imports = [ inputs.nixos-facter-modules.nixosModules.facter ];
      facter.detected.dhcp.enable = false;
    };

    homeManager.base =
      { pkgs, lib, ... }:
      {
        # nixos-facter is Linux-only.
        home.packages = lib.optionals pkgs.stdenv.isLinux [ pkgs.nixos-facter ];
      };
  };
}

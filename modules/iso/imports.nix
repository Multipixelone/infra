{ inputs, config, ... }:
{
  flake-file.inputs.nixos-generators = {
    url = "github:nix-community/nixos-generators";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  configurations.nixos.iso.module = {
    hardware.graphics.enable = true;
    imports = with config.flake.modules.nixos; [
      "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-plasma6.nix"
      "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/channel.nix"
      wifi
      pc
    ];
  };
}

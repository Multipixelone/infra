{ config, inputs, ... }:
{
  configurations.nixos.impa.module = {
    imports = [
      inputs.disko.nixosModules.disko
      config.flake.modules.nixos.efi
    ];
  };
}

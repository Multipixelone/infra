{ config, ... }:
{
  configurations.nixos.marin.module = {
    imports = with config.flake.modules.nixos; [
      efi
      wifi
      base
    ];
  };
}

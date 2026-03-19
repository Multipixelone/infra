{ config, ... }:
{
  configurations.nixos.zelda.module = {
    imports = with config.flake.modules.nixos; [
      efi
      wifi
      laptop
      gaming
    ];
  };
}

{ config, ... }:
{
  configurations.nixos.link.module = {
    imports = with config.flake.modules.nixos; [
      efi
      pc
      gaming
    ];
  };
}

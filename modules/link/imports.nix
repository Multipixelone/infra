{ config, ... }:
{
  configurations.nixos.link.module = {
    imports = with config.flake.modules.nixos; [
      audio-output
      efi
      gaming
    ];
  };
}

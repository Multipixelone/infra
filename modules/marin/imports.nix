{ config, ... }:
{
  configurations.nixos.marin.module = {
    imports = with config.flake.modules.nixos; [
      audio-output
      efi
      wifi
      media
    ];
  };
}

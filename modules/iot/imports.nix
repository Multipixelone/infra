{ config, ... }:
{
  configurations.nixos.iot.module = {
    imports = with config.flake.modules.nixos; [
      efi
      wifi
      cloudflared
    ];
  };
}

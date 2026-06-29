{ config, ... }:
{
  configurations.darwin.fi.module = {
    imports = with config.flake.modules.darwin; [
      base
    ];
  };
}

{ config, ... }:
{
  configurations.darwin.hylia.module = {
    imports = with config.flake.modules.darwin; [
      base
    ];
  };
}

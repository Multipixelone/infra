{ inputs, ... }:
{
  configurations.nixos.iot.module =
    { config, ... }:
    {
      age.secrets."govee2mqtt-env" = {
        file = "${inputs.secrets}/iot/govee2mqtt-env.age";
        mode = "0400";
      };

      services.govee2mqtt = {
        enable = true;
        environmentFile = config.age.secrets."govee2mqtt-env".path;
      };
    };
}

{ inputs, ... }:
{
  configurations.nixos.iot.module =
    { config, ... }:
    {
      age.secrets."mosquitto-govee2mqtt-passwd" = {
        file = "${inputs.secrets}/iot/mosquitto-govee2mqtt-passwd.age";
        mode = "0400";
      };

      services.mosquitto = {
        enable = true;
        listeners = [
          {
            address = "127.0.0.1";
            port = 1883;
            users.govee2mqtt = {
              hashedPasswordFile = config.age.secrets."mosquitto-govee2mqtt-passwd".path;
              acl = [ "readwrite #" ];
            };
          }
        ];
      };
    };
}

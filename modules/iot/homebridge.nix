{
  configurations.nixos.iot.module =
    { pkgs, ... }:
    {
      services.homebridge = {
        enable = true;
        openFirewall = true;
      };

      # homebridge-govee uses the `pem` npm package which requires openssl at runtime.
      # Add openssl to the service PATH so the pem module can find it.
      systemd.services.homebridge.path = [ pkgs.openssl ];
    };
}

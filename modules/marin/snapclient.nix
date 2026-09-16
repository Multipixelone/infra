{ config, ... }:
{
  configurations.nixos.marin.module = {
    assertions = [
      {
        assertion = config.hosts.link.homeAddress != null;
        message = "hosts.link.homeAddress must be set; snapclient is restricted to home LAN IPs only.";
      }
    ];

    infra.audioOutput.snapclient = {
      enable = true;
      server =
        if config.hosts.link.homeAddress != null then
          "tcp://${config.hosts.link.homeAddress}:1704"
        else
          null;
      sink = null;
    };
  };
}

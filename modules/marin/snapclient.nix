{
  lib,
  config,
  ...
}:
{
  configurations.nixos.marin.module =
    { pkgs, ... }:
    {
      assertions = [
        {
          assertion = config.hosts.link.homeAddress != null;
          message = "hosts.link.homeAddress must be set; snapclient is restricted to home LAN IPs only.";
        }
      ];

      systemd.user.services = {
        snapclient = {
          description = "SnapCast client";
          after = [ "pipewire.service" ];
          wants = [ "pipewire.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${lib.getExe' pkgs.snapcast "snapclient"} --host ${config.hosts.link.homeAddress} --player pipewire";
          };
        };
      };
    };
}

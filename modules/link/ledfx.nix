{
  lib,
  ...
}:
{
  configurations.nixos.link.module =
    { pkgs, ... }:
    {
      home-manager.users.tunnel = {
        systemd.user.services.ledfx = {
          Unit.Description = "ledfx light control";
          Install.WantedBy = [ "graphical-session.target" ];
          Service = {
            ExecStart = lib.getExe pkgs.ledfx;
          };
        };
      };
    };
}

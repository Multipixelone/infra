{ lib, ... }:
{
  configurations.nixos.link.module =
    { pkgs, ... }:
    {
      systemd.user.services.snapclient = {
        description = "SnapCast client (link's own speakers, pinned to line-out)";
        after = [ "pipewire.service" ];
        wants = [ "pipewire.service" ];
        wantedBy = [ "default.target" ];
        serviceConfig = {
          # `-s <node.name>` targets that PipeWire sink directly, bypassing
          # PipeWire's default-sink selection - so this stays on line-out
          # even when headphones are the active default for everything else.
          ExecStart = "${lib.getExe' pkgs.snapcast "snapclient"} --player pipewire -s alsa_output.pci-0000_0e_00.4.analog-stereo tcp://127.0.0.1:1704";
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };
    };
}

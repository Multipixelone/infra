{ lib, ... }:
{
  configurations.nixos.iso.module = {
    # `base` and `pc` silence boot for daily drivers. Recovery media has to be
    # able to show why stage 1 failed, so undo that here. Duplicate kernel
    # params are resolved last-wins, hence mkAfter rather than trying to drop
    # the `quiet` that `pc` appends.
    boot.plymouth.enable = lib.mkForce false;
    boot.consoleLogLevel = lib.mkForce 4;
    boot.initrd.verbose = lib.mkForce true;
    boot.kernelParams = lib.mkAfter [
      "loglevel=4"
      "systemd.show_status=true"
      "rd.udev.log_level=notice"
      "udev.log_priority=notice"
    ];
  };
}

{ lib, ... }:
{
  configurations.nixos.iso.module = {
    # Keep recovery media explicitly verbose, independent of role defaults,
    # so it can show why stage 1 failed. Duplicate kernel params are resolved
    # last-wins, hence mkAfter for these recovery-specific settings.
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

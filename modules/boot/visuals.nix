{
  flake.modules.nixos = {
    base = {
      boot.kernelParams = [ "boot.shell_on_fail" ];
    };
    # Only laptops get a quiet graphical boot. Other roles retain the NixOS
    # defaults for visible kernel, initrd and systemd boot output.
    laptop = {
      boot.consoleLogLevel = 0;
      boot.initrd.verbose = false;
      boot.kernelParams = [
        "rd.udev.log_level=3"
        "udev.log_priority=3"
        "systemd.show_status=error"
        "quiet"
      ];
      boot.plymouth = {
        enable = true;
        # theme = "nixos-bgrt";
        # themePackages = with pkgs; [
        #   nixos-bgrt-plymouth
        # ];
      };
    };
  };
}

{ lib, ... }:
{
  configurations.nixos.link.module =
    { config, ... }:
    let
      # Preserve the normal hardware/root arguments, replacing only settings
      # that suppress diagnostics. Limine adds a child entry for this NixOS
      # specialisation to each generation's boot menu.
      normalKernelParams = lib.filter (
        param:
        !(builtins.elem param [
          "quiet"
          "splash"
          "nowatchdog"
        ])
        && !(lib.any (prefix: lib.hasPrefix prefix param) [
          "loglevel="
          "nmi_watchdog="
          "softlockup_panic="
          "hung_task_panic="
          "panic="
          "systemd.show_status="
          "rd.systemd.show_status="
          "systemd.log_level="
          "rd.systemd.log_level="
          "udev.log_level="
          "udev.log_priority="
          "rd.udev.log_level="
          "drm.debug="
          "log_buf_len="
        ])
      ) config.boot.kernelParams;
    in
    {
      specialisation.boot-debug.configuration = {
        system.nixos.tags = [ "boot-debug" ];

        boot = {
          plymouth.enable = lib.mkForce false;
          consoleLogLevel = lib.mkForce 7;
          initrd.verbose = lib.mkForce true;
          kernelParams = lib.mkForce (
            normalKernelParams
            ++ [
              "loglevel=7"
              "ignore_loglevel"
              "printk.time=1"
              "log_buf_len=16M"
              # Show initcall entry/exit so an unfinished driver probe is visible.
              "initcall_debug"
              "systemd.show_status=true"
              "rd.systemd.show_status=true"
              "systemd.log_level=debug"
              "rd.systemd.log_level=debug"
              "udev.log_level=debug"
              "rd.udev.log_level=debug"
              # DRM driver and modesetting logs, without per-frame vblank spam.
              "drm.debug=0x06"
              # Keep a lockup's stack trace on screen instead of auto-rebooting.
              "nmi_watchdog=nopanic,1"
              "softlockup_panic=0"
              "hung_task_panic=0"
              "panic=0"
              # Allow Alt+SysRq+l/w/t stack/task dumps even during the initrd.
              "sysrq_always_enabled"
            ]
          );
          kernel.sysctl = {
            "kernel.watchdog" = lib.mkForce 1;
            "kernel.nmi_watchdog" = lib.mkForce 1;
            "kernel.softlockup_panic" = lib.mkForce 0;
            "kernel.hardlockup_panic" = lib.mkForce 0;
            "kernel.hung_task_panic" = lib.mkForce 0;
            "kernel.hung_task_timeout_secs" = lib.mkForce 60;
            "kernel.hung_task_all_cpu_backtrace" = lib.mkForce 1;
            "kernel.sysrq" = lib.mkForce 1;
          };
        };

        # Keep verbose messages and reduce the unsynced log window after reset.
        services.journald.settings.Journal = {
          Storage = "persistent";
          SyncIntervalSec = "1s";
          RateLimitIntervalSec = 0;
        };
      };
    };
}

{ lib, config, ... }:
{
  configurations.nixos.minish.module = {
    wsl = {
      enable = true;
      defaultUser = config.flake.meta.owner.username;
      startMenuLaunchers = true;
      wslConf.network = {
        # Keep the declarative FQDN and DNS search domain from the base module.
        generateHosts = false;
        generateResolvConf = false;
      };
    };

    # WSL boots via Microsoft's kernel; the host has no bootloader of its own.
    boot.loader.limine.enable = lib.mkForce false;
  };
}

{ lib, config, ... }:
{
  configurations.nixos.minish.module = {
    wsl = {
      enable = true;
      defaultUser = config.flake.meta.owner.username;
      startMenuLaunchers = true;
    };

    # WSL generates /etc/resolv.conf itself; let it own DNS instead of
    # systemd-resolved (enabled by base via modules/network/dns.nix).
    services.resolved.enable = false;

    # WSL boots via Microsoft's kernel; the host has no bootloader of its own.
    boot.loader.limine.enable = lib.mkForce false;
  };
}

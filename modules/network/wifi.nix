{ lib, config, ... }:
{
  flake.modules.nixos.wifi = {
    networking.networkmanager = {
      enable = true;
      wifi.backend = lib.mkDefault "iwd"; # Faster and more reliable than wpa_supplicant
      dns = lib.mkDefault "systemd-resolved";
    };

    networking.wireless.iwd = {
      enable = lib.mkDefault true;
      settings = {
        IPv6.Enabled = true;
        Settings.AutoConnect = true;
        # General = {
        #   EnableNetworkConfiguration = true; # Built-in DHCP client
        #   AddressRandomization = "network"; # MAC randomization for privacy
        # };
        Network.EnableIPv6 = true;
      };
    };

    users.extraGroups.networkmanager.members = [ config.flake.meta.owner.username ];
  };
}

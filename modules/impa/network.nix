{ config, lib, ... }:
let
  address = config.hosts.impa.homeAddress;
in
{
  configurations.nixos.impa.module = {
    networking = {
      networkmanager = {
        enable = true;
        dns = "none";
        ensureProfiles.profiles.impa-ethernet = {
          connection = {
            id = "impa-ethernet";
            type = "ethernet";
            autoconnect = true;
          };
          ipv4 = {
            address1 = "${address}/24";
            gateway = "192.168.6.1";
            method = "manual";
            dns = "127.0.0.1;";
            ignore-auto-dns = true;
          };
          ipv6 = {
            method = "disabled";
            ignore-auto-dns = true;
          };
        };
      };
      wireless.enable = lib.mkForce false;
      nameservers = [ "127.0.0.1" ];
    };
  };
}

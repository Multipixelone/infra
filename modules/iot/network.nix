{
  inputs,
  config,
  ...
}:
let
  iotHost = config.hosts.iot;
in
{
  configurations.nixos.iot.module =
    { config, ... }:
    {
      age.secrets."wifi".file = "${inputs.secrets}/wifi/home.age";

      networking = {
        networkmanager = {
          enable = true;
          ensureProfiles = {
            environmentFiles = [ config.age.secrets."wifi".path ];
            profiles = {
              cjnfrw-iot = {
                connection = {
                  id = "cjnfrw-iot";
                  type = "wifi";
                  interface-name = "wlp5s0";
                  autoconnect = true;
                };
                wifi = {
                  mode = "infrastructure";
                  ssid = "cjnfrw-iot";
                };
                wifi-security = {
                  key-mgmt = "wpa-psk";
                  psk = "$CJNFRW_IOT_PSK";
                };
                ipv4 = {
                  address1 = "${iotHost.iotAddress}/24";
                  gateway = "192.168.5.1";
                  method = "manual";
                  never-default = true;
                };
                ipv6 = {
                  addr-gen-mode = "stable-privacy";
                  method = "auto";
                };
              };
              ethernet = {
                connection = {
                  id = "ethernet";
                  type = "ethernet";
                };
                ipv4 = {
                  address1 = "${iotHost.homeAddress}/24";
                  gateway = "192.168.8.1";
                  method = "manual";
                };
                ipv6 = {
                  addr-gen-mode = "stable-privacy";
                  method = "auto";
                };
              };
            };
          };
        };
      };
    };
}

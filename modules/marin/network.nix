{
  inputs,
  config,
  ...
}:
let
  marinHost = config.hosts.marin;
in
{
  configurations.nixos.marin.module =
    { config, ... }:
    {
      age.secrets."wifi".file = "${inputs.secrets}/wifi/home.age";

      networking = {
        # broken on broadcom-sta
        wireless.iwd.enable = false;
        # prefer ipv4 (plexamp fix)
        getaddrinfo = {
          precedence = {
            "::ffff:0:0/96" = 100;
          };
        };
        networkmanager = {
          enable = true;
          wifi.backend = "wpa_supplicant";
          ensureProfiles = {
            environmentFiles = [ config.age.secrets."wifi".path ];
            profiles = {
              cjnfrw-iot = {
                connection = {
                  id = "cjnfrw-iot";
                  type = "wifi";
                  interface-name = "wlp2s0";
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
                  address1 = "${marinHost.homeAddress}/24";
                  gateway = "192.168.5.1";
                  method = "manual";
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
                  address1 = "${marinHost.iotAddress}/24";
                  gateway = "192.168.7.1";
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

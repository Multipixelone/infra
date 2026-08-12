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
                  # No interface-name pin: iwd ships 80-iwd.link with
                  # `NamePolicy=keep kernel`, so the Intel 3165 comes up as
                  # wlan0, not the predictable wlp5s0. Pinning the predictable
                  # name made this profile permanently unactivatable, which cut
                  # iot off the 192.168.5.0/24 IoT VLAN (Kasa/TP-Link devices).
                  # The profile is matched by type + SSID instead.
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

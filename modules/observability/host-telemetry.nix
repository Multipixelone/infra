{ config, lib, ... }:
let
  telemetryHosts = [
    "iot"
    "marin"
  ];
  exporterPort = 9100;
  linkAddress = config.hosts.link.homeAddress;

  hostModule =
    hostName:
    let
      hostAddress = config.hosts.${hostName}.homeAddress;
      chain = "nixos-host-telemetry";
    in
    { config, ... }:
    {
      assertions = [
        {
          assertion = hostAddress != null && linkAddress != null;
          message = "${hostName} telemetry requires LAN addresses for both ${hostName} and link";
        }
        {
          assertion =
            config.services.prometheus.exporters.node.listenAddress == hostAddress
            && !config.services.prometheus.exporters.node.openFirewall
            && lib.elem "systemd" config.services.prometheus.exporters.node.enabledCollectors;
          message = "${hostName} node exporter must bind to its LAN address with the systemd collector and a closed automatic firewall";
        }
      ];

      services.prometheus.exporters.node = {
        enable = true;
        listenAddress = hostAddress;
        port = exporterPort;
        openFirewall = false;
        enabledCollectors = [ "systemd" ];
      };

      # Insert this before nixpkgs' broad interface/conntrack accepts: only
      # Link's central Prometheus may initiate a node-exporter connection.
      networking.firewall = {
        extraCommands = ''
          iptables -w -N ${chain} 2>/dev/null || iptables -w -F ${chain}
          iptables -w -A ${chain} -s ${linkAddress}/32 -j nixos-fw-accept
          iptables -w -A ${chain} -j nixos-fw-refuse
          iptables -w -I nixos-fw 1 -p tcp --dport ${toString exporterPort} -j ${chain}
        '';
        extraStopCommands = ''
          iptables -w -D nixos-fw -p tcp --dport ${toString exporterPort} -j ${chain} 2>/dev/null || true
          iptables -w -F ${chain} 2>/dev/null || true
          iptables -w -X ${chain} 2>/dev/null || true
        '';
      };
    };
in
{
  configurations.nixos = lib.genAttrs telemetryHosts (hostName: {
    module = hostModule hostName;
  });
}

{ config, ... }:
{
  configurations.darwin.hylia.module =
    { pkgs, ... }:
    let
      address = config.hosts.hylia.wireguard.ipv4Address;
    in
    {
      launchd.daemons.node-exporter = {
        serviceConfig = {
          ProgramArguments = [
            "${pkgs.prometheus-node-exporter}/bin/node_exporter"
            "--web.listen-address=${address}:9100"
          ];
          KeepAlive = true;
          RunAtLoad = true;
          StandardOutPath = "/var/log/node-exporter.log";
          StandardErrorPath = "/var/log/node-exporter.log";
        };
      };
    };
}

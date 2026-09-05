{ config, ... }:
let
  linkHost = config.hosts.link;
in
{
  configurations.nixos.link.module =
    { pkgs, ... }:
    {
      networking = {
        networkmanager.enable = false;
        interfaces.enp6s0.ipv4.addresses = [
          {
            address = linkHost.homeAddress;
            prefixLength = 24;
          }
        ];
        interfaces.enp6s0.useDHCP = false;
        useDHCP = false;
        defaultGateway = "192.168.6.1";
      };

      # `net.core.default_qdisc = cake` (modules/security/network.nix) only
      # attaches cake to each hardware queue under `mq` with `bandwidth
      # unlimited` -- i.e. no shaping at all. Without a rate, cake cannot hold
      # the queue, so under parallel uploads it forms at the real bottleneck
      # (the NIC ring, then Verizon's gear) where there is no AQM. Measured
      # during a CI push: 202 retransmits per 10260 segments (~2%), 200 TCP
      # timeouts in ten seconds, and connections occasionally exhausting their
      # retries -- which reached attic as `error sending request`.
      #
      # 950mbit rather than 1000: cake needs headroom below the line rate to
      # keep the queue on this side, where it can manage it. The line is
      # symmetric gigabit and the NIC negotiates 1000, so this gives up ~5% of
      # theoretical throughput that saturation was destroying anyway.
      #
      # Replacing the `mq` root with a single cake instance is deliberate --
      # one shared rate is the point of shaping -- and costs multiqueue
      # softirq spread, which a desktop CPU absorbs fine at this rate.
      systemd.services.cake-egress-shaping = {
        description = "Shape enp6s0 egress so cake's AQM actually engages";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.iproute2}/bin/tc qdisc replace dev enp6s0 root cake bandwidth 950mbit";
          ExecStop = "${pkgs.iproute2}/bin/tc qdisc del dev enp6s0 root";
        };
      };
    };
}

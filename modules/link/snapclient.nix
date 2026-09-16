_: {
  configurations.nixos.link.module.infra.audioOutput.snapclient = {
    enable = true;
    server = "tcp://127.0.0.1:1704";
    # `-s <node.name>` pins playback to line-out even when another sink is
    # the PipeWire default.
    sink = "alsa_output.pci-0000_0e_00.4.analog-stereo";
  };
}

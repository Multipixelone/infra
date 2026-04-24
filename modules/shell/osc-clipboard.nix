{
  # `osc` (theimpostor/osc) provides `osc copy`/`osc paste` which relay
  # clipboard data to the host terminal via the OSC 52 escape sequence.
  # Works transparently over SSH — no X11/Wayland forwarding required.
  # Example: `echo hi | osc copy`
  flake.modules.homeManager.base =
    { pkgs, ... }:
    {
      home.packages = [ pkgs.osc ];
    };
}

{
  flake.modules.homeManager.base =
    { pkgs, lib, ... }:
    {
      home.packages =
        (with pkgs; [
          kubectl
          flyctl
          just
          devenv
        ])
        # Linux-only hardware/perf tooling.
        ++ lib.optionals pkgs.stdenv.isLinux (
          with pkgs;
          [
            sysstat
            i2c-tools
            lm_sensors
            ethtool
            pciutils
            usbutils
          ]
        );
    };
}

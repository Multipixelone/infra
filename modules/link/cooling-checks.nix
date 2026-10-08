{ config, lib, ... }:
let
  host = config.flake.nixosConfigurations.link;
in
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      packages = {
        link-cooling-config = host.config.link.cooling.package;
        link-argb-config = host.config.link.coolerArgb.package;
      };
      checks.link-cooling-config =
        pkgs.runCommand "link-cooling-config-check"
          {
            nativeBuildInputs = [
              (pkgs.python3.withPackages (ps: [
                ps.tomlkit
                ps.openrgb-python
              ]))
              pkgs.fakeroot
            ];
          }
          ''
            export PYTHONDONTWRITEBYTECODE=1
            mkdir -p /tmp/opencode
            python3 ${./tests/cooling_config_test.py} \
              ${lib.getExe host.config.link.cooling.package} \
              ${lib.getExe host.pkgs.coolercontrol.coolercontrold} \
              ${../../lib/link-cooling-config.py} \
              ${../../lib/link-argb-config.py} \
              ${lib.getExe pkgs.fakeroot}
            touch "$out"
          '';
    };
}

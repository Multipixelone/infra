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
      checks.link-rgb-config =
        pkgs.runCommand "link-rgb-config-check"
          {
            nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.openrgb-python ])) ];
          }
          ''
            export PYTHONDONTWRITEBYTECODE=1
            mkdir -p /tmp/opencode
            python3 ${./tests/rgb_config_test.py} \
              ${../../lib/link-argb-config.py} \
              ${host.config.link.ledfxOpenrgb.settingsFile} \
              ${./tests/fixtures/ledfx-config.json} \
              ${./tests/fixtures/openrgb-devices.json} \
              ${./tests/fixtures/openrgb-board-six-pixel.json}
            touch "$out"
          '';
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
              ${lib.getExe pkgs.fakeroot} \
              ${host.config.link.ledfxOpenrgb.settingsFile}
            touch "$out"
          '';
    };
}

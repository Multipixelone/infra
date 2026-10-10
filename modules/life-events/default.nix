{ lib, ... }:
let
  data = ../../data/life-events.json;
  schema = ../../data/life-events.schema.json;
in
{
  options.flake.lifeEvents = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    readOnly = true;
    description = "Canonical life events, including private events; consumers must honor visibility and never publish notes.";
  };
  config = {
    flake.lifeEvents = builtins.fromJSON (builtins.readFile data);

    perSystem =
      { pkgs, self', ... }:
      {
        packages.life-events = pkgs.writers.writePython3Bin "life-events" {
          libraries = [ pkgs.python3Packages.jsonschema ];
          flakeIgnore = [ "E501" ];
        } (builtins.readFile ../../lib/life-events.py);

        checks.life-events-data =
          pkgs.runCommand "life-events-data-check"
            {
              nativeBuildInputs = [
                (pkgs.python3.withPackages (packages: [ packages.jsonschema ]))
              ];
            }
            ''
              export PYTHONDONTWRITEBYTECODE=1
              ${lib.getExe self'.packages.life-events} validate ${data} ${schema}
              python3 ${./tests/data_test.py} ${../../lib/life-events.py} ${data} ${schema} \
                ${lib.getExe self'.packages.life-events}
              touch "$out"
            '';
      };
  };
}

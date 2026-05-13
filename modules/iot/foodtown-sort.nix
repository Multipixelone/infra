{ inputs, ... }:
{
  configurations.nixos.iot.module =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      # Skill files consumed by foodtown-sort.py at runtime.
      skillDir = ./skills;

      # python3 defaults to 3.14 which has broken pydantic-core (ModuleNotFoundError: No module named 'pydantic_core._pydantic_core').
      # Bake the python312 path so patchShebangs can't pick up 3.14, and scrub PYTHON* env that HA's systemd service leaks
      # (it sets PYTHONPATH to a 3.14 package list; 3.12 then finds pure-python modules but fails to load 3.14-ABI .so files).
      foodtownSort =
        let
          pyEnv = pkgs.python312.withPackages (ps: [ ps.openai ]);
        in
        pkgs.writeShellScriptBin "foodtown-sort" ''
          unset PYTHONPATH PYTHONHOME PYTHONNOUSERSITE
          exec ${pyEnv}/bin/python3 ${./foodtown-sort.py} "$@"
        '';

      # Wrapper exposes secrets + config as env vars so the Python script
      # stays free of Nix-store paths and can be tested manually.
      runner = pkgs.writeShellApplication {
        name = "ha-foodtown-sort";
        runtimeInputs = [ foodtownSort ];
        text = ''
          export HA_URL="http://localhost:8123"
          export FOODTOWN_ENTITY="todo.foodtown"
          export FOODTOWN_SKILL_DIR="${skillDir}"
          export HA_TOKEN_FILE="${config.age.secrets."homeassistant-token".path}"
          OPENAI_API_KEY="$(< "${config.age.secrets."openai".path}")"
          export OPENAI_API_KEY
          exec foodtown-sort "$@"
        '';
      };
    in
    {
      age.secrets = {
        "homeassistant-token" = {
          file = "${inputs.secrets}/iot/homeassistant-token.age";
          owner = "hass";
          group = "hass";
          mode = "0400";
        };
        "openai" = {
          file = "${inputs.secrets}/ai/openai.age";
          owner = "hass";
          group = "hass";
          mode = "0400";
        };
      };

      services.home-assistant.config.shell_command = {
        sort_foodtown = "${lib.getExe runner}";
      };
    };
}

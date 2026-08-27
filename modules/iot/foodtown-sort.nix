_: {
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

      # Bake the interpreter path so patchShebangs cannot change it, and scrub
      # the PYTHON* environment inherited from Home Assistant before starting.
      foodtownSort =
        let
          pyEnv = pkgs.python3.withPackages (ps: [ ps.openai ]);
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
      services.home-assistant.config.shell_command = {
        sort_foodtown = "${lib.getExe runner}";
      };
    };
}

_: {
  configurations.nixos.iot.module =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      # Skill files consumed by nudge-writer.py at runtime.
      skillDir = ./skills/nudge-writer;

      # python3 defaults to 3.14 which has broken pydantic-core. Bake the
      # python312 path so patchShebangs can't pick up 3.14, and scrub PYTHON*
      # env that HA's systemd service leaks. See foodtown-sort.nix for the
      # original incident notes.
      nudgeWriter =
        let
          pyEnv = pkgs.python312.withPackages (ps: [ ps.openai ]);
        in
        pkgs.writeShellScriptBin "nudge-writer" ''
          unset PYTHONPATH PYTHONHOME PYTHONNOUSERSITE
          exec ${pyEnv}/bin/python3 ${./nudge-writer.py} "$@"
        '';

      # Wrapper exposes secrets + config as env vars so the Python script
      # stays free of Nix-store paths and can be tested manually.
      runner = pkgs.writeShellApplication {
        name = "ha-nudge-writer";
        runtimeInputs = [ nudgeWriter ];
        text = ''
          export HA_URL="http://localhost:8123"
          export NUDGE_SKILL_DIR="${skillDir}"
          export NUDGE_MODEL="''${NUDGE_MODEL:-gpt-5-nano}"
          export NUDGE_VALID_MINUTES="''${NUDGE_VALID_MINUTES:-30}"
          export HA_TOKEN_FILE="${config.age.secrets."homeassistant-token".path}"
          OPENAI_API_KEY="$(< "${config.age.secrets."openai".path}")"
          export OPENAI_API_KEY
          exec nudge-writer "$@"
        '';
      };
    in
    {
      services.home-assistant.config.shell_command = {
        write_nudges = "${lib.getExe runner}";
      };
    };
}

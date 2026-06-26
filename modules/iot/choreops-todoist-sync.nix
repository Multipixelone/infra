{
  # Surfaces Finn's assigned ChoreOps chores (HA custom integration) into Todoist
  # and writes completions back. A deterministic bash reconcile loop on a 15-min
  # systemd timer — no agent/LLM. Runs on iot as `hass` so it can read the local
  # HA REST API (localhost:8123) and the hass-owned agenix secrets.
  #
  # Both secrets are already declared elsewhere for this host and are reused here
  # via systemd Environment= (paths, not contents):
  #   - homeassistant-token  (modules/iot/homeassistant.nix)
  #   - todoist              (modules/iot/todoist.nix)
  configurations.nixos.iot.module =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      sync = pkgs.writeShellApplication {
        name = "choreops-todoist-sync";
        runtimeInputs = with pkgs; [
          curl
          jq
          coreutils
        ];
        text = builtins.readFile ./choreops-todoist-sync.sh;
      };
    in
    {
      systemd.services.choreops-todoist-sync = {
        description = "Reconcile ChoreOps chores <-> Todoist";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "hass";
          Group = "hass";
          # Creates/owns /var/lib/choreops-todoist-sync (state file lives here).
          StateDirectory = "choreops-todoist-sync";
          Environment = [
            "HA_TOKEN_FILE=${config.age.secrets."homeassistant-token".path}"
            "TODOIST_TOKEN_FILE=${config.age.secrets."todoist".path}"
          ];
          ExecStart = lib.getExe sync;

          # Hardening (User=hass, so no DynamicUser). StateDirectory stays writable
          # under ProtectSystem=strict; agenix secrets live in /run, not /home.
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ProtectControlGroups = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          LockPersonality = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
          ];
        };
      };

      systemd.timers.choreops-todoist-sync = {
        description = "Periodic ChoreOps <-> Todoist sync";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/15";
          Persistent = true;
          RandomizedDelaySec = "60";
        };
      };
    };
}

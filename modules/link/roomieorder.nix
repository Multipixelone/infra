# roomieorder — HA button → Amazon order → Google Sheets.
#
# Runs on `link` as a systemd **user** service (bound to graphical-session)
# because the buy flow is a headed Chromium that needs $WAYLAND_DISPLAY. Mirrors
# modules/link/commutecompass.nix (same openclaw wrapper, same agenix idiom).
#
# Home Assistant on `iot` POSTs to this service over the LAN; see
# modules/iot/roomieorder.nix for the generated buttons. catalog.json is the
# single source of truth, shared by both hosts via inputs.secrets.
{ inputs, config, ... }:
let
  # iot reaches link's intake port over the home LAN. `config.hosts` is the
  # flake-parts-level host registry (hosts.nix); it is NOT on the nixos config,
  # so capture both addresses here at the outer level.
  linkLanIp = config.hosts.link.homeAddress;
in
{
  nixpkgs.config.allowUnfreePackages = [
    "google-chrome"
  ];

  flake-file.inputs.roomieorder = {
    url = "github:Multipixelone/roomieorder";
  };

  configurations.nixos.link.module =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      # Same openclaw wrapper commutecompass.nix uses: tunnel's npm-global binary
      # with nodejs on PATH for its `#!/usr/bin/env node` shebang.
      openclawPkg = pkgs.writeShellApplication {
        name = "openclaw";
        runtimeInputs = [ pkgs.nodejs ];
        text = ''
          exec /home/tunnel/.npm-global/bin/openclaw "$@"
        '';
      };

      # --- Session-check idle signal (Wayland/Hyprland) --------------------
      # The session probe pops a *headed* Chrome window on the live desktop, so
      # busy_gate waits until the operator is away before firing. Hyprland has
      # no "current idle seconds" query, so we run a tiny swayidle daemon
      # (ext-idle-notify) that timestamps when the seat goes idle into a marker
      # under $XDG_RUNTIME_DIR and clears it on the first input. idleCmd then
      # reports `now − marker (+ the 4s detection offset)`, or 0 when active.
      # Both run as tunnel user services, so they share one $XDG_RUNTIME_DIR.
      # A missing/zero reading makes busy_gate defer (fail-closed) — the
      # operator never gets a window in their face mid-work.
      idleTracker = pkgs.writeShellApplication {
        name = "roomieorder-idle-tracker";
        runtimeInputs = [
          pkgs.swayidle
          pkgs.coreutils
        ];
        text = ''
          marker="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/roomieorder.idle-since"
          # Double quotes → this shell expands $marker into the swayidle arg
          # before swayidle re-runs it via `sh -c` (where $marker is unset).
          exec swayidle -w \
            timeout 4 "date +%s > $marker" \
            resume "rm -f $marker"
        '';
      };
      idleCmd = pkgs.writeShellApplication {
        name = "roomieorder-idle-seconds";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          marker="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/roomieorder.idle-since"
          if [ -f "$marker" ]; then
            echo $(( $(date +%s) - $(cat "$marker") + 4 ))
          else
            echo 0
          fi
        '';
      };
    in
    {
      imports = [ inputs.roomieorder.nixosModules.default ];

      age.secrets."roomieorder" = {
        file = "${inputs.secrets}/roomieorder/env.age";
        owner = "tunnel";
        mode = "0400";
      };
      # Google service-account key, decrypted to a stable path the env file
      # (GOOGLE_SERVICE_ACCOUNT_JSON) points at. Optional — only read when
      # ROOMIEORDER_SHEET_ID is set; until then the app uses a no-op logger.
      # NB: do NOT set an explicit `path` under /run/agenix — agenix does
      # `mkdir -p $(dirname path)` per custom-path secret, which turns
      # /run/agenix into a real directory and makes the final
      # `ln -sfn /run/agenix.d/N /run/agenix` fail ("cannot overwrite
      # directory"), silently dropping EVERY system secret. The default path
      # /run/agenix/roomieorder-gcp is exactly what env.age's
      # GOOGLE_SERVICE_ACCOUNT_JSON already points at.
      age.secrets."roomieorder-gcp" = {
        file = "${inputs.secrets}/roomieorder/gcp.age";
        owner = "tunnel";
        mode = "0400";
      };

      services.roomieorder = {
        enable = true;
        # Single source of truth — the same file the HA button generator on iot
        # reads (modules/iot/roomieorder.nix). Replace the placeholder ASINs with
        # real ones before going live.
        catalogFile = "${inputs.secrets}/roomieorder/catalog.json";
        environmentFile = config.age.secrets."roomieorder".path;

        # SAFETY: keep true until every item has reached its review page via
        # `roomieorder dry-run <item>` (PLAN §4, §5). Flip to false for the live
        # buy once verified.
        dryRun = false;
        wayland = true;

        openclaw = {
          package = openclawPkg;
          # Real chat id is sourced from OPENCLAW_TARGET in env.age so it stays
          # out of /nix/store (EnvironmentFile= wins over Environment=).
          target = "";
        };

        extraEnvironment = {
          # Bind to link's LAN address so HA on iot can reach it (default
          # 127.0.0.1 is unreachable cross-host).
          ROOMIEORDER_HOST = linkLanIp;
          ROOMIEORDER_PORT = "8723";
          ROOMIEORDER_DAILY_CAP = "150.00";
          # Session probe waits for the operator to be away before popping the
          # headed Chrome review window. Require 5 min of idle (tune freely);
          # idle seconds come from the swayidle marker daemon below. To also
          # gate by clock, set ROOMIEORDER_SESSION_CHECK_WINDOW = "03:00-08:00".
          ROOMIEORDER_SESSION_CHECK_IDLE_MINUTES = "5";
          ROOMIEORDER_SESSION_CHECK_IDLE_CMD = lib.getExe idleCmd;
          # gamemoded isn't on the service PATH, so point the gamemode-skip at
          # an absolute binary — otherwise the default `gamemoded -s` fails and
          # is read as "not gaming" (the probe wouldn't pause for a game).
          ROOMIEORDER_SESSION_CHECK_GAMEMODE_CMD = "${lib.getExe' pkgs.gamemode "gamemoded"} -s";

          # Review-page screenshots are sent to Telegram via openclaw, whose
          # gateway only reads local media from a fixed allowlist of roots
          # (system tmp, <configDir>/media, <stateDir>/media|canvas|…). Write
          # shots into openclaw's own media dir — an absolute path under an
          # allowed root — so the attachment isn't rejected with "Local media
          # path is not under an allowed directory". The relative default (under
          # the unit's StateDirectory) is both relative and outside the allowlist,
          # so the separate openclaw-gateway process can't read it.
          ROOMIEORDER_SHOTS_DIR = "/home/tunnel/.openclaw/media/roomieorder";
        };
      };

      # Publish the unit's non-secret env (baseEnv) as a dotenv file so the
      # roomieorder dev shell / a terminal `roomieorder` can mirror exactly what
      # the service runs with — same catalog, Chrome, caps, host/port and state
      # paths — instead of re-deriving them. The repo's .envrc dotenvs this plus
      # /run/agenix/roomieorder (the secrets). Single source: the module's
      # baseEnv. Holds no secrets, so /etc exposure matches the unit's
      # world-readable Environment=.
      environment.etc."roomieorder/env".source = config.services.roomieorder.envFile;

      # Idle tracker feeding ROOMIEORDER_SESSION_CHECK_IDLE_CMD. Bound to the
      # graphical session exactly like the roomieorder unit so it shares the
      # same Wayland seat and $XDG_RUNTIME_DIR (where the marker lives). hypridle
      # (link's main idle daemon is zelda-only and laptop-specific) is left
      # untouched — this is a dedicated, side-effect-free marker writer.
      systemd.user.services.roomieorder-idle = {
        description = "roomieorder idle tracker (swayidle marker for session-check)";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = lib.getExe idleTracker;
          Restart = "on-failure";
          RestartSec = "10s";
        };
      };

      # Intake port for HA on iot. The LAN is trusted (every other link service
      # opens its port the same way); to scope it to iot only, switch to an
      # nftables `extraInputRules` rule keyed on ${iotLanIp}.
      networking.firewall.allowedTCPPorts = [ 8723 ];
    };
}

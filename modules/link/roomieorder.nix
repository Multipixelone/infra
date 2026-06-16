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
    { config, pkgs, ... }:
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

      # Intake port for HA on iot. The LAN is trusted (every other link service
      # opens its port the same way); to scope it to iot only, switch to an
      # nftables `extraInputRules` rule keyed on ${iotLanIp}.
      networking.firewall.allowedTCPPorts = [ 8723 ];
    };
}

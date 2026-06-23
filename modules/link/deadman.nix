{ inputs, ... }:
{
  # I1 — Dead-man's switch (Kestrel out-of-band backstop).
  #
  # Telegram is Kestrel's only delivery sink, routed through the
  # openclaw-gateway user service (modules/link/openclaw.nix). The
  # in-workspace watchdog can't report the gateway being dead, because the
  # same outage takes it down too. This timer pings the gateway health
  # endpoint independently and, on sustained failure, POSTs *directly* to the
  # Telegram bot API — never through OpenClaw — so the alert survives the
  # gateway/cron being down.
  configurations.nixos.link.module =
    {
      config,
      pkgs,
      ...
    }:
    let
      # Gateway health: GET /health returns {"ok":true,"status":"live"} when
      # live; when the gateway is down the port refuses the connection and
      # curl fails. Either way → counted as a failure. Debounced so a brief
      # blip doesn't page: alert only after THRESHOLD consecutive failures
      # (timer fires every 2min → ≈6min sustained outage), and recover with a
      # single quiet message, never repeating either.
      deadmanScript = pkgs.writeShellApplication {
        name = "openclaw-deadman";
        runtimeInputs = [
          pkgs.curl
          pkgs.coreutils
        ];
        text = ''
          HEALTH_URL="http://localhost:18789/health"
          THRESHOLD=3
          STATE="''${STATE_DIRECTORY:-/tmp/openclaw-deadman}"
          COUNT_FILE="$STATE/fail_count"
          ALERTED="$STATE/alerted"

          mkdir -p "$STATE"
          count=0
          [ -f "$COUNT_FILE" ] && count=$(cat "$COUNT_FILE")

          # Direct Telegram bot API — deliberately not via openclaw, so the
          # alert path is independent of the thing it's watching. Token + chat
          # id come from the agenix EnvironmentFile, never the nix store.
          send() {
            curl -fsS -m 10 \
              "https://api.telegram.org/bot''${TELEGRAM_BOT_TOKEN}/sendMessage" \
              --data-urlencode "chat_id=''${TELEGRAM_CHAT_ID}" \
              --data-urlencode "text=$1" >/dev/null || true
          }

          if resp=$(curl -fsS -m 5 "$HEALTH_URL" 2>/dev/null) \
            && printf '%s' "$resp" | grep -q '"ok":true'; then
            # Healthy. If we'd previously paged, send one recovery note.
            if [ -f "$ALERTED" ]; then
              send "✅ openclaw-gateway recovered on link ($(date '+%H:%M'))."
              rm -f "$ALERTED"
            fi
            echo 0 > "$COUNT_FILE"
          else
            count=$((count + 1))
            echo "$count" > "$COUNT_FILE"
            if [ "$count" -ge "$THRESHOLD" ] && [ ! -f "$ALERTED" ]; then
              send "🚨 openclaw-gateway DOWN on link — health check failed ''${count}× (≥''${THRESHOLD}/2min). Telegram delivery is offline."
              touch "$ALERTED"
            fi
          fi
        '';
      };
    in
    {
      # Dedicated secret for the out-of-band path: an env file with
      # TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID. Kept separate from openclaw's
      # own telegram config on purpose — the backstop must not depend on the
      # thing it backs up. Owner tunnel / 0400, injected via EnvironmentFile.
      age.secrets."telegram-deadman" = {
        file = "${inputs.secrets}/ai/telegram-deadman.age";
        owner = "tunnel";
        group = "users";
        mode = "0400";
      };

      # Runs as a tunnel user unit (like openclaw-gateway), but as an
      # independent systemd timer — fired by systemd, not by the gateway/cron,
      # so it keeps probing even when they're dead.
      home-manager.users.tunnel.systemd.user = {
        services.openclaw-deadman = {
          Unit.Description = "Dead-man's switch: alert via Telegram bot API if openclaw-gateway is down";
          Service = {
            Type = "oneshot";
            ExecStart = "${deadmanScript}/bin/openclaw-deadman";
            EnvironmentFile = config.age.secrets."telegram-deadman".path;
            # Persists the debounce counter / alerted flag across timer runs
            # at ~/.local/state/openclaw-deadman.
            StateDirectory = "openclaw-deadman";
          };
        };

        timers.openclaw-deadman = {
          Unit.Description = "Periodic dead-man's switch check for openclaw-gateway";
          Timer = {
            OnBootSec = "2min";
            OnUnitActiveSec = "2min";
            Unit = "openclaw-deadman.service";
          };
          Install.WantedBy = [ "timers.target" ];
        };
      };
    };
}

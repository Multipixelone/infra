{
  lib,
  inputs,
  config,
  ...
}:
let
  scrapedHosts = map (host: config.hosts.${host}.hostName) (
    builtins.attrNames config.observability.nodes
  );
in
{
  # onFailure remains the declarative opt-in. Registry hosts page through
  # Alertmanager; other hosts use the direct backstop.
  flake.modules.nixos.base =
    { pkgs, config, ... }:
    let
      managed = lib.elem config.networking.hostName scrapedHosts;
      notify-telegram = pkgs.writeShellApplication {
        name = "notify-telegram";
        runtimeInputs = [
          pkgs.curl
          pkgs.coreutils
          pkgs.systemd
        ];
        text = (import ../lib/alert-format.nix) + ''
          export TZDIR=${pkgs.tzdata}/share/zoneinfo
          unit="$1"
          journal_tail=$(journalctl -u "$unit" -n 15 --no-pager -o cat 2>/dev/null | tail -c 2000 || true)
          msg=$(render_alert firing OptedInUnitFailed "$unit on ${config.networking.hostName}" "$(date +%s)" "" \
            "Systemd unit $unit failed on ${config.networking.hostName}" \
            "Run journalctl -u $unit -n 50 on ${config.networking.hostName}")
          msg="$msg
          Journal:
          ''${journal_tail:-<no journal output>}"
          curl -fsS -m 10 \
            "https://api.telegram.org/bot''${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=''${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=$msg" >/dev/null
        '';
      };
    in
    {
      # The unit reads the secret's .path, so it has to be suppressed with the
      # declaration on installer media rather than left dangling.
      config = lib.mkIf (!config.infra.installerMedia) {
        # Env file with TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID. Moved here from
        # modules/link/deadman.nix so every NixOS host can alert; the .age is
        # already encrypted to every system key, so widening the tier needed no
        # rekey. deadman.nix still references it by name.
        age.secrets."telegram-deadman" = {
          file = "${inputs.secrets}/ai/telegram-deadman.age";
          owner = "tunnel";
          group = "users";
          mode = "0400";
        };

        systemd.services."notify-telegram@" = {
          description =
            if managed then
              "Failure paging owned by Alertmanager (%i)"
            else
              "Telegram alert for failed unit %i";
          serviceConfig = {
            Type = "oneshot";
            # systemd reads EnvironmentFile as root, so the tunnel-owned 0400
            # secret works for this root-run unit.
            ExecStart = if managed then "${pkgs.coreutils}/bin/true" else "${lib.getExe notify-telegram} %i";
          }
          // lib.optionalAttrs (!managed) {
            EnvironmentFile = config.age.secrets."telegram-deadman".path;
          };
        };
      };
    };
}

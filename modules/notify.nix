{ lib, inputs, ... }:
{
  # Reusable fail-loud sink: any system unit can add
  #   onFailure = [ "notify-telegram@%n.service" ];
  # and its failure (plus a journal tail) lands on the phone via the Telegram
  # bot API. Same delivery path as the deadman switch (modules/link/deadman.nix)
  # and deliberately independent of openclaw — the alert must not depend on
  # anything it might be reporting about.
  # On `base`, not `pc`: the headless hosts are the ones with nobody watching a
  # screen, so an `onFailure` there is worth more than on the desktop. While
  # this sat on `pc` it silently reached only link and zelda, and any
  # onFailure = [ "notify-telegram@%n.service" ] written on impa, iot or marin
  # would have pointed at a unit that does not exist on that host.
  flake.modules.nixos.base =
    { pkgs, config, ... }:
    let
      notify-telegram = pkgs.writeShellApplication {
        name = "notify-telegram";
        runtimeInputs = [
          pkgs.curl
          pkgs.coreutils
          pkgs.systemd
        ];
        text = ''
          unit="$1"
          tail=$(journalctl -u "$unit" -n 15 --no-pager -o cat 2>/dev/null | tail -c 3500 || true)
          msg="🚨 FAILED: $unit on ${config.networking.hostName}

          ''${tail:-<no journal output>}"
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
          description = "Telegram alert for failed unit %i";
          serviceConfig = {
            Type = "oneshot";
            # systemd reads EnvironmentFile as root, so the tunnel-owned 0400
            # secret works for this root-run unit.
            EnvironmentFile = config.age.secrets."telegram-deadman".path;
            ExecStart = "${lib.getExe notify-telegram} %i";
          };
        };
      };
    };
}

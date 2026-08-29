{ lib, inputs, ... }:
{
  # Shared rclone plumbing for the onedrive remote (link + zelda via pc).
  #
  # The config CANNOT live read-only in the nix store / agenix tmpfs: personal
  # OneDrive rotates the refresh token on every use and rclone persists it by
  # rewriting rclone.conf in place. A frozen token gets invalidated by
  # Microsoft within weeks (this silently killed backups for a month in
  # 2026-07). So nix seeds *state*: the agenix blob is copied once into a
  # root-owned mutable file that rclone owns from then on, and is re-copied
  # only when the blob itself changes (fresh token re-encrypted + deployed).
  flake.modules.nixos.pc =
    { pkgs, config, ... }:
    let
      cfg = config.infra.rclone;

      rclone-seed = pkgs.writeShellApplication {
        name = "rclone-seed";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          seed=${cfg.seedFile}
          conf=${cfg.configFile}
          marker=${cfg.stateDir}/.seed-hash

          seed_hash=$(sha256sum "$seed" | cut -d' ' -f1)
          if [ ! -s "$conf" ] || [ "$seed_hash" != "$(cat "$marker" 2>/dev/null || true)" ]; then
            install -m 0600 -o root -g root "$seed" "$conf"
            echo "$seed_hash" > "$marker"
            echo "seeded $conf from $seed"
          fi
        '';
      };

      rclone-health = pkgs.writeShellApplication {
        name = "rclone-health";
        runtimeInputs = [
          cfg.package
          pkgs.gnugrep
          pkgs.coreutils
        ];
        text = ''
          if ! out=$(rclone lsd "${cfg.remote}:" --max-depth 1 --config ${cfg.configFile} \
                --retries 1 --low-level-retries 3 --contimeout 30s 2>&1); then
            echo "$out"
            if grep -qiE 'invalid_grant|couldn.t fetch token|token expired' <<<"$out"; then
              echo "ONEDRIVE TOKEN DEAD (invalid_grant) — run 'onedrive-reauth' on ${config.networking.hostName}"
            fi
            exit 1
          fi
          echo "rclone health OK on ${cfg.remote}:"
        '';
      };

      # Everyday interactive access to the REAL state config. sudo wrapper
      # (via the setuid path, not pkgs.sudo) instead of a group-writable conf:
      # no token exposure to `users`, and immune to rclone resetting ownership
      # on its atomic rewrite.
      rclone-onedrive = pkgs.writeShellApplication {
        name = "rclone-onedrive";
        text = ''
          exec /run/wrappers/bin/sudo ${lib.getExe cfg.package} --config ${cfg.configFile} "$@"
        '';
      };

      onedrive-reauth = pkgs.writeShellApplication {
        name = "onedrive-reauth";
        runtimeInputs = [
          cfg.package
          pkgs.coreutils
          inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
        ];
        text = ''
          sudo=/run/wrappers/bin/sudo
          conf=${cfg.configFile}
          secrets_repo="''${SECRETS_REPO:-$HOME/Documents/Git/nix-secrets}"
          age_file="restic/${config.networking.hostName}rclone.age"

          echo "==> seeding state config (no-op if already current)"
          $sudo systemctl start rclone-seed.service

          # No headless flag needed: rclone always prints the auth URL to
          # stdout as a fallback, whether or not it manages to pop a browser.
          echo "==> reconnecting ${cfg.remote}: — open the printed URL to complete OAuth"
          $sudo rclone --config "$conf" config reconnect "${cfg.remote}:"

          echo "==> verifying"
          $sudo rclone --config "$conf" lsd "${cfg.remote}:" --max-depth 1

          if [ ! -d "$secrets_repo" ]; then
            echo "WARNING: $secrets_repo not found — skipping re-encryption." >&2
            echo "The fresh token lives only in $conf; re-encrypt it into $age_file soon." >&2
            exit 0
          fi

          echo "==> re-encrypting fresh token into $secrets_repo/$age_file"
          tmp=$(mktemp -p "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}")
          trap 'shred -u "$tmp" 2>/dev/null || rm -f "$tmp"' EXIT
          $sudo cat "$conf" > "$tmp"
          (cd "$secrets_repo" && EDITOR="cp $tmp" agenix -e "$age_file" -i "$HOME/.ssh/agenix")

          echo "==> done. To make it durable:"
          echo "    cd $secrets_repo && git add $age_file && git commit -m 'chore: rotate ${config.networking.hostName} rclone token' && git push"
          echo "    then bump the secrets input (just update) and rebuild."
          echo "    (The next deploy re-seeds $conf with this same token — harmless.)"
        '';
      };
    in
    {
      options.infra.rclone = {
        remote = lib.mkOption {
          type = lib.types.str;
          default = "onedrive";
          description = "Name of the rclone remote defined in the seeded config.";
        };
        stateDir = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/rclone";
          description = "Directory holding the mutable rclone state config.";
        };
        configFile = lib.mkOption {
          type = lib.types.str;
          default = "${cfg.stateDir}/rclone.conf";
          description = "The mutable runtime rclone config every consumer must pass explicitly.";
        };
        seedFile = lib.mkOption {
          type = lib.types.str;
          default = config.age.secrets."restic/rclone".path;
          description = "Decrypted agenix blob the state config is seeded from.";
        };
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.rclone;
          description = "rclone package used by every consumer and put on PATH.";
        };
      };

      # `seedFile` defaults to the secret's .path and the seed unit bakes it in,
      # so installer media drops the whole tier along with the declaration.
      config = lib.mkIf (!config.infra.installerMedia) {
        age.secrets."restic/rclone".file =
          "${inputs.secrets}/restic/${config.networking.hostName}rclone.age";

        systemd.tmpfiles.rules = [
          "d ${cfg.stateDir} 0700 root root -"
          # re-normalize perms in case rclone's atomic rewrite changed them
          "z ${cfg.configFile} 0600 root root - -"
        ];

        # Not wantedBy anything: consumers pull it in via wants/after, so a
        # freshly-deployed blob is picked up on the next consumer start.
        systemd.services.rclone-seed = {
          description = "Seed mutable rclone config from the agenix blob";
          onFailure = [ "notify-telegram@%n.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe rclone-seed;
          };
        };

        systemd.services.rclone-health = {
          description = "rclone ${cfg.remote} auth health check";
          wants = [
            "rclone-seed.service"
            "network-online.target"
          ];
          after = [
            "rclone-seed.service"
            "network-online.target"
          ];
          onFailure = [ "notify-telegram@%n.service" ];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe rclone-health;
          };
        };
        # Deliberately offset from the 00:00/01:00 backups so two rclone
        # processes don't refresh the rotating token concurrently. The daily
        # run also keeps the refresh token warm between backups.
        systemd.timers.rclone-health = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "12:00";
            Persistent = true;
            RandomizedDelaySec = "10m";
          };
        };

        environment.systemPackages = [
          cfg.package
          rclone-onedrive
          onedrive-reauth
        ];
      };
    };
}

{ inputs, ... }:
{
  # Commit signing (GPG) — live.
  #
  # The secret key lives in the nix-secrets repo as `gpg/signing-key.age`,
  # encrypted to every host in `systems`, and is imported into the keyring by
  # the activation script below (guarded by pathExists, so a host without the
  # secrets input still evaluates).
  #
  # To rotate the key:
  #   1. gpg --full-generate-key   (ed25519)
  #   2. gpg --armor --export-secret-keys <KEY-ID> \
  #        | agenix -e gpg/signing-key.age   (in Multipixelone/nix-secrets)
  #   3. Update `signingKey` below to the new long ID / fingerprint.
  #   4. Add the *public* key to GitHub as a signing key (Verified badge).
  #
  # The imported key is kept passphrase-less on Linux hosts so that commits made
  # from headless contexts (ssh, openclaw-driven sessions) can sign without a
  # prompt; it is protected by disk permissions and FDE instead. pinentry-curses
  # is still wired up so `gpg --change-passphrase` and friends have a UI.
  flake.modules.homeManager.base =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      signingKey = "59BF38D05371C5E9";
      secretFile = "${inputs.secrets}/gpg/signing-key.age";
      hasSecret = builtins.pathExists secretFile;
    in
    {
      programs.gpg.enable = true;

      # Without an agent there is no pinentry at all, and every signature fails
      # with "gpg: signing failed: No pinentry". macOS keeps its own agent
      # setup, so this is Linux-only.
      services.gpg-agent = lib.mkIf pkgs.stdenv.hostPlatform.isLinux {
        enable = true;
        pinentry.package = pkgs.pinentry-curses;
        defaultCacheTtl = 86400;
        maxCacheTtl = 86400;
      };

      programs.git.settings = {
        gpg.format = "openpgp";
        commit.gpgSign = true;
        tag.gpgSign = true;
      }
      // lib.optionalAttrs (signingKey != "") {
        user.signingKey = signingKey;
      };

      age.secrets = lib.mkIf hasSecret {
        "gpg-signing-key".file = secretFile;
      };

      home.activation = lib.mkIf hasSecret {
        # The secret is decrypted by the agenix launchd agent (RunAtLoad, at
        # login), which is decoupled from `darwin-rebuild switch`. During a
        # rebuild the file may not be mounted yet, so guard on readability and
        # let the import happen on the next activation once login has run it.
        gpgImportSigningKey = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          keyPath="${config.age.secrets."gpg-signing-key".path}"
          if [ -r "$keyPath" ]; then
            $DRY_RUN_CMD ${pkgs.gnupg}/bin/gpg --batch --import "$keyPath" || true
          else
            verboseEcho "gpg signing key not yet decrypted; import deferred to next activation"
          fi
        '';
      };
    };
}

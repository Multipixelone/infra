{ inputs, ... }:
{
  # Commit signing (GPG) — scaffolded but OFF.
  #
  # `commit.gpgSign` stays false until the key is in place. To turn it on:
  #   1. Generate a key:  gpg --full-generate-key   (ed25519 recommended)
  #   2. Add the *secret* key to the nix-secrets repo, encrypted with agenix:
  #        gpg --armor --export-secret-keys <KEY-ID> \
  #          | agenix -e gpg/signing-key.age   (in Multipixelone/nix-secrets)
  #   3. Set `signingKey` below to the key's long ID / fingerprint.
  #   4. Add the *public* key to GitHub as a signing key (Verified badge).
  #   5. Flip `commit.gpgSign` / `tag.gpgSign` to true and rebuild.
  #
  # Once `gpg/signing-key.age` exists in the secrets repo, the agenix secret and
  # the keyring import below activate automatically (guarded by pathExists), so
  # steps 3 + 5 are the only edits left here.
  flake.modules.homeManager.base =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      signingKey = "59BF38D05371C5E9"; # TODO: GPG key ID, once generated
      secretFile = "${inputs.secrets}/gpg/signing-key.age";
      hasSecret = builtins.pathExists secretFile;
    in
    {
      programs.gpg.enable = true;

      programs.git.settings = {
        gpg.format = "openpgp";
        commit.gpgSign = true; # flip to true once the key is registered on GitHub
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

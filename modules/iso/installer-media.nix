{ inputs, lib, ... }:
{
  # The ISO imports `pc` (and through it `base`) for the desktop, user and
  # tooling an installer needs, but it boots with freshly generated host keys
  # that are in no agenix recipient list — every secret it declares is
  # undecryptable there, and one of them (wireguard/nixos.age) does not even
  # exist. The cost is not theoretical: agenix embeds each `.file` store path
  # in the activation script, which makes the whole nix-secrets checkout a
  # runtime reference of the system closure, so it is copied into the squashfs
  # written to a USB stick.
  #
  # Declared on `base` so every host that evaluates a secret-declaring module
  # can read the flag.
  flake.modules.nixos.base = {
    options.infra.installerMedia = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        This configuration is portable installer/recovery media. Modules that
        declare `age.secrets` suppress them when it is set, together with the
        consumers reading `.path` — the two must always be guarded as a pair,
        or the consumer forces a missing attribute and aborts evaluation.
      '';
    };
  };

  configurations.nixos.iso.module =
    { config, ... }:
    let
      fromSecrets =
        config.age.secrets
        |> lib.filterAttrs (_: secret: lib.hasPrefix "${inputs.secrets}" (toString secret.file));
    in
    {
      infra.installerMedia = true;

      assertions = [
        {
          assertion = fromSecrets == { };
          message =
            "ISO declares nix-secrets-backed age.secrets (${lib.concatStringsSep ", " (lib.attrNames fromSecrets)}); "
            + "each one makes the entire nix-secrets checkout a runtime reference of the installer squashfs. "
            + "Guard the declaration and every consumer of its .path with `lib.mkIf (!config.infra.installerMedia)`.";
        }
      ];
    };
}

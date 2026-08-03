{
  inputs,
  config,
  lib,
  ...
}:
let
  user = config.flake.meta.owner.username;
in
{
  # Authenticate private `github:` flake inputs (e.g. prem-tweet) on hylia.
  #
  # Nix's `github:` fetcher reads the token ONLY from the `access-tokens`
  # setting (src/libfetchers/github.cc, getAccessToken) — it never consults
  # netrc, so Determinate's netrc-file (used for FlakeHub) does nothing here.
  # NixOS hosts get the token via modules/nixpkgs/attic.nix, which `!include`s
  # github/nix.age under nixos.base. hylia is nix-darwin + Determinate (which
  # sets `nix.enable = false` and owns /etc/nix), so that module never applies
  # here — wire the same secret in through Determinate's custom conf instead.
  configurations.darwin.hylia.module =
    { config, ... }:
    {
      # github/nix.age is `access-tokens = github.com=<token>` in nix.conf
      # syntax, encrypted to the shared `tunnel` user key (same key used on
      # NixOS), so hylia's home-manager agenix can decrypt it.
      home-manager.users.${user}.age.secrets."github/nix".file =
        "${inputs.secrets}/github/nix.age";

      # Determinate's /etc/nix/nix.conf does `!include nix.custom.conf` and does
      # NOT re-set access-tokens afterwards, so an !include appended to the
      # custom conf is honoured. `text` is types.lines, so mkAfter appends after
      # Determinate's generated settings rather than clobbering them. The `!`
      # (optional) form keeps activation from failing if the secret has not been
      # decrypted yet on first switch; the token stays out of /nix/store.
      environment.etc."nix/nix.custom.conf".text = lib.mkAfter ''
        !include ${config.home-manager.users.${user}.age.secrets."github/nix".path}
      '';
    };
}

{ inputs, ... }:
{
  # colmena re-evaluates each node through eval-config.nix's default `lib`, which
  # lacks the flake version-info overlay that `nixpkgs.lib.nixosSystem` carries.
  # Left to their defaults these two options resolve to `pre-git`/null on the
  # colmena path and to the real nixpkgs stamp on the nixosConfigurations path,
  # so the same host builds two different toplevels. Pinning them to the flake
  # input's own values collapses both paths onto one derivation.
  flake.modules.nixos.base = {
    system.nixos.versionSuffix = inputs.nixpkgs.lib.trivial.versionSuffix;
    system.nixos.revision = inputs.nixpkgs.rev or null;

    system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or null;
  };
}

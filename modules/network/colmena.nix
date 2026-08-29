{ inputs, ... }:
{
  # Only the machines deploys are launched from need the CLI. In `base` an
  # upstream-main build failure would break every host's closure, not just
  # deploys. `pc` covers link and, via modules/laptop.nix, zelda.
  flake.modules.nixos.pc =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        inputs.colmena.packages.${pkgs.stdenv.hostPlatform.system}.colmena
      ];
    };
}

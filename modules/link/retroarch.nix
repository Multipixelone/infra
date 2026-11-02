{
  config,
  lib,
  rootPath,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      packages.libretro-azahar = pkgs.callPackage "${rootPath}/pkgs/libretro-azahar" { };
    };

  # Only link opts into this core. Do not add a 3DS save policy: the existing
  # synced user directory and mod layout must first be verified by its owner.
  configurations.nixos.link.module.home-manager.users.${config.flake.meta.owner.username} =
    { pkgs, ... }:
    {
      gaming.retroarch.extraCores = [
        (pkgs.callPackage "${rootPath}/pkgs/libretro-azahar" { })
      ];
    };
}

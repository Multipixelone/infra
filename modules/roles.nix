{ config, lib, ... }:
let
  # Roles that carry a NixOS module. Roles without one (wsl, nas, tablet,
  # mobile) are metadata only and inject nothing.
  roleModules = {
    inherit (config.flake.modules.nixos) server laptop edge;
    # The desktop tier module is still called `pc`.
    desktop = config.flake.modules.nixos.pc;
  };
  nixosHosts = lib.filterAttrs (_: host: host.isNixOS) config.hosts;
in
{
  configurations.nixos = lib.mapAttrs (_: host: {
    module.imports = lib.attrVals (lib.intersectLists host.roles (lib.attrNames roleModules)) roleModules;
  }) nixosHosts;
}

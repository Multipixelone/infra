{ lib, config, ... }:
let
  nixosHosts = lib.filterAttrs (_: host: host.isNixOS) config.hosts;
in
{
  configurations.nixos = lib.mapAttrs (_name: host: {
    deployment.tags = host.roles;
  }) nixosHosts;
}

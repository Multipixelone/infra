{ lib, config, ... }:
let
  nixosHosts = lib.filterAttrs (_: host: host.isNixOS) config.hosts;
  serviceHosts =
    config.servicePublication.hosts
    |> lib.filterAttrs (
      _: host:
      host.managedByNixOS
      && (
        host.capabilities.reverseProxy || host.capabilities.internalDns || host.capabilities.publicConnector
      )
    );
in
{
  configurations.nixos = lib.mapAttrs (name: host: {
    deployment.tags =
      host.roles ++ lib.optional (builtins.hasAttr name serviceHosts) "service-publication";
  }) nixosHosts;
}

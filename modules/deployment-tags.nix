{ lib, config, ... }:
let
  nixosHosts = lib.filterAttrs (_: host: host.isNixOS) config.hosts;
  # A route backend that is not its own proxy still receives generated
  # firewall rules, so it has to ride the same deploy as the proxy.
  backendHosts =
    config.flake.servicePublicationInventory.routes
    |> lib.attrValues
    |> map (route: route.backend.host)
    |> lib.unique;
  serviceHosts =
    config.servicePublication.hosts
    |> lib.filterAttrs (
      name: host:
      host.managedByNixOS
      && (
        host.capabilities.reverseProxy
        || host.capabilities.internalDns
        || host.capabilities.publicConnector
        || lib.elem name backendHosts
      )
    );
in
{
  configurations.nixos = lib.mapAttrs (name: host: {
    deployment.tags =
      host.roles ++ lib.optional (builtins.hasAttr name serviceHosts) "service-publication";
  }) nixosHosts;
}

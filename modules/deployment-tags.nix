{ lib, config, ... }:
let
  # Setting `deployment` at all is what puts a host in the colmena hive, so the
  # filter here is the hive membership test: parked or unreachable hosts stay in
  # nixosConfigurations and in checks, but colmena never sees them.
  nixosHosts = lib.filterAttrs (
    _: host: host.isNixOS && host.deployable && host.deployAddress != null
  ) config.hosts;
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
    # `[ name ]` so `--on @<host>` always selects that host. Host names and the
    # roles enum (modules/hosts.nix) are disjoint; keep them that way.
    deployment.tags = [
      name
    ]
    ++ host.roles
    ++ lib.optional (builtins.hasAttr name serviceHosts) "service-publication";
  }) nixosHosts;
}

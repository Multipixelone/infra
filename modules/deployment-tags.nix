{ lib, config, ... }:
let
  nixosHosts = lib.filterAttrs (_: host: host.isNixOS) config.hosts;
  # Setting `deployment` at all is what puts a host in the colmena hive, so
  # writing it for exactly the hosts.<name>.inHive set is what makes that field
  # the membership test: parked or unreachable hosts stay in nixosConfigurations
  # and in checks, but colmena never sees them.
  hiveHosts = lib.filterAttrs (_: host: host.inHive) config.hosts;
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
  configurations.nixos = lib.mkMerge [
    (lib.mapAttrs (name: host: {
      # `[ name ]` so `--on @<host>` always selects that host. Host names and the
      # roles enum (modules/hosts.nix) are disjoint; keep them that way.
      deployment.tags = [
        name
      ]
      ++ host.roles
      ++ lib.optional (builtins.hasAttr name serviceHosts) "service-publication";
    }) hiveHosts)

    # A host that claims to be deployable but has no address is a half-finished
    # registration: inHive silently goes false and colmena never mentions the
    # host again. Assert it inside the host's own eval rather than at the flake
    # level, so one misfiled entry fails that host's check instead of every
    # `nix eval` in the repo.
    (lib.mapAttrs (name: host: {
      module.assertions = [
        {
          assertion = host.deployable -> host.deployAddress != null;
          message = "hosts.${name} is deployable but has no deployAddress, so colmena would silently never see it; set hosts.${name}.homeAddress or hosts.${name}.wireguard.ipv4Address, or set hosts.${name}.deployable = false";
        }
      ];
    }) nixosHosts)
  ];
}

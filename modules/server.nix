{ config, lib, ... }:
let
  # A suspended server is an outage; headless hosts must stay reachable.
  sleepPolicy = {
    AllowSuspend = false;
    AllowHibernation = false;
    AllowHybridSleep = false;
    AllowSuspendThenHibernate = false;
  };
  # Compare like for like in both directions: only the keys the policy owns.
  policyKeysIn = nixos: lib.intersectAttrs sleepPolicy nixos.systemd.sleep.settings.Sleep;
  nixosHosts = lib.filterAttrs (_: host: host.isNixOS) config.hosts;
  isServer = host: lib.elem "server" host.roles;

  nonServerGuard =
    { config, ... }:
    {
      assertions = [
        {
          assertion = policyKeysIn config == { };
          message = "server sleep policy: ${config.networking.hostName} is not a server and must not set the server sleep keys";
        }
      ];
    };
in
{
  flake.modules.nixos.server = {
    systemd.sleep.settings.Sleep = sleepPolicy;
    imports = [
      (
        { config, ... }:
        {
          assertions = [
            {
              assertion = policyKeysIn config == sleepPolicy;
              message = "server sleep policy: ${config.networking.hostName} must keep suspend and hibernation disabled";
            }
          ];
        }
      )
    ];
  };

  configurations.nixos = lib.mapAttrs (
    _: host:
    if isServer host then
      { module.imports = [ config.flake.modules.nixos.server ]; }
    else
      { module = nonServerGuard; }
  ) nixosHosts;
}

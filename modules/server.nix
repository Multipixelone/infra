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
  nonServerHosts = lib.filterAttrs (_: host: !(lib.elem "server" host.roles)) nixosHosts;

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
    imports = [
      config.flake.modules.nixos.base
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
    systemd.sleep.settings.Sleep = sleepPolicy;
  };

  configurations.nixos = lib.mapAttrs (_: _: { module = nonServerGuard; }) nonServerHosts;
}

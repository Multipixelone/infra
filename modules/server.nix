{ config, lib, ... }:
let
  sleepPolicy = {
    AllowSuspend = false;
    AllowHibernation = false;
    AllowHybridSleep = false;
    AllowSuspendThenHibernate = false;
  };
  policyKeys = lib.attrNames sleepPolicy;
  serverHosts = lib.filterAttrs (_: host: host.isNixOS && lib.elem "server" host.roles) config.hosts;
  serverHostNames = lib.attrNames serverHosts;
  representativeNonServers = [
    "link"
    "zelda"
    "minish"
  ];
in
{
  flake.modules.nixos.server.systemd.sleep.settings.Sleep = sleepPolicy;

  configurations.nixos = lib.mapAttrs (_: _: {
    module.imports = [ config.flake.modules.nixos.server ];
  }) serverHosts;

  perSystem =
    { pkgs, ... }:
    let
      evaluatedSleep = lib.mapAttrs (
        _: nixos: nixos.config.systemd.sleep.settings.Sleep
      ) config.flake.nixosConfigurations;
      serversInheritPolicy = lib.all (
        hostName: lib.all (key: evaluatedSleep.${hostName}.${key} or null == sleepPolicy.${key}) policyKeys
      ) serverHostNames;
      nonServersExcludePolicy = lib.all (
        hostName: lib.all (key: !(builtins.hasAttr key evaluatedSleep.${hostName})) policyKeys
      ) representativeNonServers;
      checkedPolicy =
        assert lib.assertMsg (
          serverHostNames == [
            "impa"
            "iot"
            "marin"
          ]
        ) "server sleep policy: expected current NixOS server set to be impa, iot, and marin";
        assert lib.assertMsg serversInheritPolicy
          "server sleep policy: every NixOS server must disable suspend and hibernation";
        assert lib.assertMsg nonServersExcludePolicy
          "server sleep policy: desktop, laptop, and WSL representatives must not inherit server-only keys";
        assert lib.assertMsg (
          evaluatedSleep.zelda.HibernateDelaySec or null == "300s"
        ) "server sleep policy: Zelda must retain its independent laptop hibernation delay";
        {
          inherit serverHostNames representativeNonServers sleepPolicy;
        };
    in
    {
      checks.server-sleep-policy = pkgs.writeText "server-sleep-policy-check.json" (
        builtins.toJSON checkedPolicy + "\n"
      );
    };
}

{
  lib,
  config,
  inputs,
  withSystem,
  ...
}:
let
  deployableHosts = lib.filterAttrs (_: cfg: cfg.deployment != null) config.configurations.nixos;
  nixosConfigs = config.flake.nixosConfigurations;

  # `colmena.<name>` is an ssh_config alias generated in modules/ssh.nix; it
  # carries the deploy key, which a bare IP or an fqdn would not match.
  resolveTargetHost =
    name: cfg:
    if cfg.deployment.targetHost != null then
      cfg.deployment.targetHost
    else if config.hosts.${name}.deployAddress != null then
      "colmena.${name}"
    else
      throw "host '${name}' is in the colmena hive but has no deployAddress; set hosts.${name}.homeAddress or hosts.${name}.wireguard.ipv4Address, or set hosts.${name}.deployable = false";
in
{
  config.flake-file.inputs.colmena = {
    # Newest release is v0.4.0 (2023); main is where the maintained work lands.
    url = "github:zhaofengli/colmena/main";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  config.flake.colmenaHive = inputs.colmena.lib.makeHive (
    {
      meta = {
        nixpkgs = import inputs.nixpkgs {
          system = "x86_64-linux";
          overlays = [ ];
        };
        # A filterless apply would target link (the desktop this is usually run
        # from) and every parked host.
        allowApplyAll = false;
      };
    }
    // lib.mapAttrs (name: cfg: {
      # Pass the whole submodule through: every option it declares mirrors an
      # upstream colmena one, so adding a knob is a single edit.
      deployment = cfg.deployment // {
        targetHost = resolveTargetHost name cfg;
      };
      nixpkgs = {
        pkgs = lib.mkForce (
          withSystem nixosConfigs.${name}.config.nixpkgs.hostPlatform.system ({ pkgs, ... }: pkgs)
        );
        config = lib.mkForce { };
      };
      imports = [ cfg.module ];
    }) deployableHosts
  );
}

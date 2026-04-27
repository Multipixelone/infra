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
  inherit (config) hosts;
  defaultTargetHost =
    name:
    let
      nixos = nixosConfigs.${name} or null;
    in
    if nixos != null then nixos.config.networking.fqdn else name;
  # Check if host has a resolvable address (wireguard or home)
  hasResolvableAddress =
    name:
    let
      host = hosts.${name} or null;
    in
    host != null && (host.wireguard.ipv4Address != null || host.homeAddress != null);

  resolveTargetHost =
    name: cfg:
    if cfg.deployment.targetHost != null then
      cfg.deployment.targetHost
    else if hasResolvableAddress name then
      "colmena.${name}"
    else
      (defaultTargetHost name);
in
{
  config.flake-file.inputs.colmena = {
    url = "github:zhaofengli/colmena";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  config.flake.colmenaHive = inputs.colmena.lib.makeHive (
    {
      meta.nixpkgs = import inputs.nixpkgs {
        system = "x86_64-linux";
        overlays = [ ];
      };
    }
    // lib.mapAttrs (name: cfg: {
      deployment = {
        targetHost = resolveTargetHost name cfg;
        inherit (cfg.deployment) targetUser tags allowLocalDeployment;
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

{
  lib,
  config,
  inputs,
  withSystem,
  ...
}:
let
  hiveHosts = lib.filterAttrs (_: host: host.inHive) config.hosts;
  nixosConfigs = config.flake.nixosConfigurations;

  # The hive is built from the registry, not by scanning configurations.nixos for
  # a non-null `deployment`, so hosts.<name>.inHive is the only membership test.
  # modules/deployment-tags.nix is the sole writer of `deployment` and writes it
  # for exactly that set; compare the two rather than trusting either, because
  # configurations.nixos is a lazyAttrsOf any module may extend and a node added
  # there would otherwise be deployed with no registry entry behind it.
  taggedNames =
    config.configurations.nixos |> lib.filterAttrs (_: cfg: cfg.deployment != null) |> lib.attrNames;
  hiveNames = lib.attrNames hiveHosts;

  checkedHiveHosts =
    assert lib.assertMsg (taggedNames == hiveNames) ''
      colmena hive membership disagrees with the host registry: configurations.nixos sets `deployment` for [${lib.concatStringsSep " " taggedNames}], but hosts.<name>.inHive selects [${lib.concatStringsSep " " hiveNames}]. Membership is owned by modules/hosts.nix, so add or fix the registry entry rather than setting `deployment` by hand.
    '';
    hiveHosts;
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
    // lib.mapAttrs (
      name: _host:
      let
        cfg = config.configurations.nixos.${name};
      in
      {
        # Pass the whole submodule through: every option it declares mirrors an
        # upstream colmena one, so adding a knob is a single edit.
        deployment = cfg.deployment // {
          # `colmena.<name>` is an ssh_config alias generated in modules/ssh.nix
          # from the same registry projection; it carries the deploy key, which a
          # bare IP or an fqdn would not match. inHive already guarantees a
          # deployAddress, so there is no unreachable-node branch left to throw
          # from.
          targetHost =
            if cfg.deployment.targetHost != null then cfg.deployment.targetHost else "colmena.${name}";
        };
        nixpkgs = {
          pkgs = lib.mkForce (
            withSystem nixosConfigs.${name}.config.nixpkgs.hostPlatform.system ({ pkgs, ... }: pkgs)
          );
          config = lib.mkForce { };
        };
        imports = [ cfg.module ];
      }
    ) checkedHiveHosts
  );
}

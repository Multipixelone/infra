{
  rootPath,
  ...
}:
{
  nixpkgs.overlays = [
    (final: _prev: {
      grafana-alloy = final.callPackage "${rootPath}/pkgs/grafana-alloy" { };
    })
  ];

  perSystem =
    { pkgs, ... }:
    {
      packages.grafana-alloy = pkgs.grafana-alloy;
    };

  configurations.nixos.link.module =
    { pkgs, ... }:
    {
      services.alloy.package = pkgs.grafana-alloy;
    };
}

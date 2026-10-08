_:
{
  perSystem = { pkgs, ... }: {
    packages.games-dashboard = pkgs.callPackage ../../pkgs/games-dashboard { };
  };
}

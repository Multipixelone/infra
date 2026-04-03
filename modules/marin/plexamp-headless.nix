{
  withSystem,
  rootPath,
  ...
}:
{
  nixpkgs.config.allowUnfreePackages = [ "plexamp-headless" ];

  perSystem =
    { pkgs, ... }:
    {
      packages.plexamp-headless = pkgs.callPackage "${rootPath}/pkgs/plexamp-headless" { };
    };

  configurations.nixos.marin.module =
    { pkgs, lib, ... }:
    let
      plexamp-headless = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.plexamp-headless
      );
    in
    {
      users.users.plexamp-headless = {
        isSystemUser = true;
        group = "plexamp-headless";
        home = "/var/lib/plexamp-headless";
      };
      users.groups.plexamp-headless = { };

      systemd.services.plexamp-headless = {
        description = "Plexamp Headless";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          User = "plexamp-headless";
          Group = "plexamp-headless";
          StateDirectory = "plexamp-headless";
          Environment = [
            "HOME=/var/lib/plexamp-headless"
            "XDG_CONFIG_HOME=/var/lib/plexamp-headless/.config"
          ];
          ExecStart = lib.getExe plexamp-headless;
          Restart = "on-failure";
          RestartSec = "5s";
        };
      };
    };
}

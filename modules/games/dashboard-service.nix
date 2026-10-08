{
  config,
  lib,
  withSystem,
  ...
}:
let
  serviceModule =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      package = withSystem pkgs.stdenv.hostPlatform.system (args: args.config.packages.games-dashboard);
    in
    {
      systemd.services.games-dashboard = {
        enable = true;
        description = "Private game server dashboard";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        path = [
          pkgs.systemd
          cfg.packages.status
          cfg.packages.logs
          cfg.packages.backup
        ];
        environment = {
          GAMES_DASHBOARD_MOCK = "0";
          GAMES_DASHBOARD_ORIGIN = "https://games.nyc.finnrut.is";
          PYTHONDONTWRITEBYTECODE = "1";
        };
        serviceConfig = {
          User = "games-dashboard";
          Group = "games-dashboard";
          ExecStart = "${lib.getExe package} --port 8780";
          Restart = "on-failure";
          RestartSec = "5s";
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          UMask = "0077";
          # games-logs executes the fixed root journal reader through setuid
          # sudo. NNP or an empty capability bounding set would break that.
          # No new sudo commands, ambient capabilities, or groups are granted.
          NoNewPrivileges = false;
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_NETLINK"
          ];
          IPAddressDeny = "any";
          IPAddressAllow = "localhost";
          # Sudo may maintain timestamps/lecture state. These exceptions do
          # not make game data, journals, secrets or the store writable.
          ReadWritePaths = [
            "-/run/sudo"
            "-/var/lib/sudo"
          ];
        };
      };
    };
in
{
  flake.modules.nixos.games-dashboard-service = serviceModule;
  configurations.nixos.link.module.imports = [ config.flake.modules.nixos.games-dashboard-service ];
}

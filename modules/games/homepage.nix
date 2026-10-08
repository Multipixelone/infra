{ config, lib, ... }:
let
  homepage = import ../../lib/games-homepage.nix { inherit lib; };
  canonical =
    config.flake.servicePublicationInventory.applications.games.canonical or "games.nyc.finnrut.is";
  dashboardUrl = "https://${canonical}";
in
{
  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      availableServers = lib.mapAttrs (id: server: server // { inherit id; }) (
        lib.filterAttrs (
          id: server:
          server.enable
          && server.targetHost == config.networking.hostName
          && builtins.elem server.game [
            "minecraft-paper"
            "terraria-tmodloader"
          ]
          && cfg.runtime.${id}.available
        ) cfg.servers
      );
      servers = lib.filterAttrs (
        id: _: config.systemd.services.${lib.removeSuffix ".service" cfg.runtime.${id}.unit}.enable
      ) availableServers;
      # Unit declarations must not depend on their own merged enable flags.
      terraria = lib.filterAttrs (_: server: server.game == "terraria-tmodloader") availableServers;
      ports = pkgs.writeText "games-homepage-ports.json" (
        builtins.toJSON (lib.mapAttrs (_: server: server.terraria.port) terraria)
      );
    in
    {
      # Apply runs after option definitions merge, including the existing
      # media group's mkForce. Ordinary mkAfter would be discarded there.
      options.services.homepage-dashboard.services = lib.mkOption {
        apply = groups: homepage.appendGroups groups (homepage.tiles servers dashboardUrl) dashboardUrl;
      };
      config = {
        assertions = [
          {
            assertion = lib.all (
              server:
              if server.game == "minecraft-paper" then
                !(builtins.elem 18777 [
                  server.minecraft.proxyPort
                  server.minecraft.serverPort
                  server.minecraft.rconPort
                ])
              else
                server.terraria.port != 18777
            ) (lib.attrValues cfg.servers);
            message = "Game ports must not collide with Homepage's loopback status adapter (18777).";
          }
        ];
        systemd.services.games-homepage-status = lib.mkIf (terraria != { }) {
          description = "Read-only loopback game port status for Homepage";
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.python3}/bin/python3 ${./homepage-status.py} ${ports}";
            DynamicUser = true;
            Restart = "on-failure";
            RestartSec = "5s";
            NoNewPrivileges = true;
            CapabilityBoundingSet = "";
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            RestrictAddressFamilies = [ "AF_INET" ];
            IPAddressDeny = "any";
            IPAddressAllow = "localhost";
          };
        };
      };
    };
}

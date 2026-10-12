{ config, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      cfg = config.flake.nixosConfigurations.link.config;
      inventory = config.flake.servicePublicationInventory;
      fixture = pkgs.writeText "link-grimoire-config.json" (
        builtins.toJSON {
          container = lib.getAttrs [
            "ports"
            "user"
            "image"
            "volumes"
            "environment"
            "extraOptions"
          ] cfg.virtualisation.oci-containers.containers.grimoire;
          backend = cfg.virtualisation.oci-containers.backend;
          route = inventory.routes."grimoire/root";
          access = inventory.cloudflare.accessApplications.grimoire;
          dns = inventory.cloudflare.dnsRecords.grimoire;
          vhost.extraConfig = cfg.services.nginx.virtualHosts."rpg.finnrut.is".extraConfig;
          certificates = cfg.security.acme.certs.service-publication-link.extraDomainNames;
          backup = {
            inherit (cfg.services.restic.backups.srv)
              paths
              exclude
              timerConfig
              passwordFile
              ;
            preStart = cfg.systemd.services.restic-backups-srv.serviceConfig.ExecStartPre;
            onFailure = cfg.systemd.services.restic-backups-srv.onFailure;
          };
          kavitaEnabled = cfg.services.kavita.enable;
          kavitaSecretDeclared = cfg.age.secrets ? kavita;
          firewallPorts = cfg.networking.firewall.allowedTCPPorts;
          tmpfiles = cfg.systemd.tmpfiles.rules;
        }
      );
    in
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.link-grimoire =
        pkgs.runCommand "link-grimoire-check"
          {
            nativeBuildInputs = [ pkgs.python3 ];
            RESTIC_EXE = lib.getExe pkgs.restic;
            NGINX_EXE = lib.getExe pkgs.nginx;
          }
          ''
            export PYTHONDONTWRITEBYTECODE=1
            python3 ${./tests/grimoire_backup_test.py} ${../../lib/grimoire-sqlite-backup.py} ${fixture}
            touch "$out"
          '';
    };
}

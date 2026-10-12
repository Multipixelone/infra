{ lib, ... }:
let
  webPort = 9481;
  dataDir = "/srv/grimoire/data";
  libraryDir = "/srv/grimoire/library";
  importedLibrary = "/srv/kavita/library";
  backupDir = "/var/backup/grimoire";
in
{
  servicePublication.applications.grimoire = {
    site = "nyc";
    public = true;
    publicHostname = "rpg.finnrut.is";
    access.policy = "family";
    homepage = {
      name = "Grimoire";
      group = "Games";
      description = "TTRPG library and campaigns";
      icon = "mdi-book-open-page-variant";
    };
    nginx.extraConfig = ''
      client_max_body_size 100M;
      proxy_request_buffering off;
      # First-account creation grants admin. Claim it through the loopback
      # origin, never through Family Access or the trusted LAN proxy surface.
      location = /api/auth/setup { return 403; }
    '';
    routes.root = {
      backend = {
        host = "link";
        port = webPort;
      };
      # Keep the origin on loopback without adding a LAN container listener.
      proxy.host = "link";
      health = {
        path = "/api/health";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 8;
      };
    };
  };

  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      sqliteBackup = pkgs.writeScriptBin "grimoire-sqlite-backup" (
        "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ../../lib/grimoire-sqlite-backup.py
      );
    in
    {
      environment.systemPackages = [
        sqliteBackup
        pkgs.sqlite
      ];

      assertions = [
        {
          assertion = config.virtualisation.oci-containers.backend == "podman";
          message = "Grimoire uses Link's existing Podman OCI runtime.";
        }
        {
          # The image has no named user or PUID/PGID entrypoint. These are
          # Link's existing tunnel:users IDs; do not change the host account.
          assertion = config.users.users.tunnel.uid == null || config.users.users.tunnel.uid == 1000;
          message = "Grimoire's container UID must match Link's tunnel account.";
        }
        {
          assertion = config.users.groups.users.gid == 100;
          message = "Grimoire's container GID must match Link's users group.";
        }
      ];

      systemd.tmpfiles.rules = [
        "d /srv/grimoire 0750 tunnel users -"
        "d ${dataDir} 0700 tunnel users -"
        "d ${libraryDir} 0775 tunnel users -"
        "d ${libraryDir}/books 0775 tunnel users -"
        "d ${libraryDir}/books/Imported 0775 tunnel users -"
        "d ${libraryDir}/maps 0775 tunnel users -"
        "d ${libraryDir}/tokens 0775 tunnel users -"
        "d ${libraryDir}/audio 0775 tunnel users -"
        "d ${libraryDir}/models 0775 tunnel users -"
        # Retain the existing paths and ownership without moving any books.
        "d /srv/kavita 0775 tunnel users -"
        "d ${importedLibrary} 0775 tunnel users -"
        # Outside application-writable directories: only the backup job can
        # replace the database snapshot, including its temporary files.
        "d ${backupDir} 0700 root root -"
      ];

      virtualisation.oci-containers.containers.grimoire = {
        autoStart = true;
        # v1.8.0 (2026-10-08), OCR variant. Registry index verified on
        # 2026-10-12; its linux/amd64 manifest is sha256:7a299c54cb51359ae81bc361363eb8738fdf35654cfa604efc5b31c046838549.
        image = "docker.io/hunterreadca/grimoire:1.8.0@sha256:3c3bad0f15462538d3058d4d2b292a18d6487ee20a20a23718263d9f8ad6eb58";
        user = "1000:100";
        ports = [ "127.0.0.1:${toString webPort}:9481" ];
        volumes = [
          "${dataDir}:/data"
          "${libraryDir}:/library"
          "${importedLibrary}:/library/books/Imported"
        ];
        environment = {
          LIBRARY_PATH = "/library";
          DATA_PATH = "/data";
          BASE_URL = "https://rpg.finnrut.is";
          WORKERS = "1";
          TZ = "America/New_York";
          UMASK = "002";
          ALLOW_PASSWORD_AUTHENTICATION = "true";
          GUEST_ACCESS_ENABLED = "false";
          BACKUP_SCHEDULE = "off";
          # SECRET_KEY is intentionally unset: upstream generates a private
          # /data/secret_key on first boot and reuses it on subsequent starts.
        };
        extraOptions = [
          "--cap-drop=ALL"
          "--security-opt=no-new-privileges"
        ];
      };

      systemd.services.podman-grimoire.unitConfig.RequiresMountsFor = [
        dataDir
        libraryDir
        importedLibrary
      ];

      # The upstream archive omits the library, signing key and character
      # portraits. Restic copies all persistent files directly; SQLite's
      # online backup API supplies the consistent database in the same job.
      infra.backup.srvPaths = [
        dataDir
        libraryDir
        importedLibrary
        backupDir
        "/var/lib/kavita"
      ];
      services.restic.backups.srv.exclude = [
        "${dataDir}/grimoire.db"
        "${dataDir}/grimoire.db-wal"
        "${dataDir}/grimoire.db-shm"
        "${dataDir}/grimoire.db-journal"
        "${dataDir}/thumbnails"
        "${dataDir}/page_cache"
      ];
      systemd.services.restic-backups-srv = {
        unitConfig.RequiresMountsFor = [
          dataDir
          libraryDir
          importedLibrary
          backupDir
          "/var/lib/kavita"
        ];
        serviceConfig.ExecStartPre = [
          "${lib.getExe sqliteBackup} ${dataDir}/grimoire.db ${backupDir}/grimoire.db"
        ];
      };
    };
}

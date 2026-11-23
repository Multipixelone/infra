{ inputs, ... }:
{
  flake-file.inputs.dvp = {
    url = "github:Multipixelone/dvp";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  servicePublication.applications.dvp = {
    site = "nyc";
    public = true;
    edgeOnly = true;
    publicHostname = "dvp.finnrut.is";
    access.policy = "finn-only";
    nginx.extraConfig = "client_max_body_size 2m;";
    routes.root = {
      proxy.host = "link";
      backend = {
        host = "link";
        port = 8790;
      };
      health = {
        # DVP requires a signed Cloudflare Access assertion at the origin too.
        path = "/";
        expectedStatuses = [ 403 ];
        timeoutSeconds = 8;
      };
    };
  };

  configurations.nixos.link.module =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      stateDir = config.services.dvp.stateDir;
      backupDir = "/var/backup/dvp";
      requiredDbs = {
        "backup.sqlite3" = [
          "devices"
          "enrollment_codes"
          "enrollment_failures"
          "versions"
          "version_parents"
        ];
        "staff.sqlite3" = [
          "staff"
          "staff_aliases"
        ];
      };
      historyDb = "history.sqlite3";
      historyTables = [
        "finals"
        "shifts"
        "minutes"
        "duties"
      ];
      sidecars = [
        "-wal"
        "-shm"
        "-journal"
      ];
      prepareBackup = pkgs.writeScript "dvp-sqlite-backup" ''
        #!${pkgs.python3}/bin/python3
        import runpy
        from pathlib import Path
        from stat import S_ISREG

        snapshot = runpy.run_path("${../../lib/grimoire-sqlite-backup.py}")["snapshot"]
        state = Path(${builtins.toJSON stateDir})
        backup = Path(${builtins.toJSON backupDir})

        def exists(path):
            try:
                path.lstat()
            except FileNotFoundError:
                return False
            return True

        def save(name, tables):
            source = state / name
            if not S_ISREG(source.lstat().st_mode):
                raise RuntimeError(f"DVP database is not a regular file: {source}")
            snapshot(source, backup / name, required_tables=tuple(tables))

        for name, tables in ${builtins.toJSON requiredDbs}.items():
            save(name, tables)

        history = ${builtins.toJSON historyDb}
        if exists(state / history):
            save(history, ${builtins.toJSON historyTables})
        elif exists(backup / history) or any(
            exists(state / (history + suffix)) for suffix in ${builtins.toJSON sidecars}
        ):
            raise SystemExit("DVP history database is missing; any previous snapshot was retained")
        else:
            print("DVP history database does not exist yet; skipping it")
      '';
    in
    {
      imports = [ inputs.dvp.nixosModules.default ];

      services.dvp = {
        enable = true;
        host = "127.0.0.1";
        port = 8790;
        stateDir = "/srv/dvp";
        openFirewall = false;
        # The local nginx proxy overwrites X-Real-IP.
        trustProxy = true;
        cloudflareAccess = {
          enable = true;
          domain = "saltandstraw.com";
          emails = [ "finn@cnwr.net" ];
          issuer = "https://frutis.cloudflareaccess.com";
          audience = "0053c1f3b2eea1bf8a606a2507833fa3af0b607d0d09896f1a93a43c16b77762";
        };
      };
      systemd.services.dvp.unitConfig.RequiresMountsFor = [ stateDir ];

      # Keep SQLite snapshots private and outside application-writable state.
      systemd.tmpfiles.rules = [ "d ${backupDir} 0700 root root -" ];
      infra.backup.srvPaths = [
        stateDir
        backupDir
      ];
      services.restic.backups.srv.exclude =
        lib.concatMap (name: map (suffix: "${stateDir}/${name}${suffix}") ([ "" ] ++ sidecars)) (
          builtins.attrNames requiredDbs ++ [ historyDb ]
        )
        ++ [ "${backupDir}/.*.tmp*" ];
      systemd.services.restic-backups-srv = {
        after = [ "dvp.service" ];
        unitConfig.RequiresMountsFor = [
          stateDir
          backupDir
        ];
        # A failed snapshot must stop Restic, not upload a stale replacement.
        serviceConfig.ExecStartPre = [ "${prepareBackup}" ];
      };
    };
}

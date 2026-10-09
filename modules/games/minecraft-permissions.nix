{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      secret = "games/minecraft/luckperms-db-password";
      ready = cfg.secretFiles ? ${secret} && builtins.pathExists cfg.secretFiles.${secret};
      definitions = builtins.fromJSON (builtins.readFile ./luckperms-libraries.json);
      libraries = lib.listToAttrs (
        map (d: lib.nameValuePair d.name (pkgs.fetchurl { inherit (d) name url sha256; })) definitions
      );
      classpath = lib.concatStringsSep ":" (
        map (name: toString libraries.${name}) [
          "asm-9.8.jar"
          "asm-commons-9.8.jar"
          "jar-relocator-1.7.jar"
        ]
      );
      cache = pkgs.runCommand "luckperms-5.5.71-libraries" { } (
        ''
          mkdir -p "$out"
        ''
        + lib.concatMapStrings (
          d:
          let
            rules =
              d.relocations
              ++ lib.optional (lib.hasPrefix "configurate-yaml" d.name) [
                "yaml"
                "org.yaml.snakeyaml"
              ];
            remapped = lib.removeSuffix ".jar" d.name + "-remapped.jar";
          in
          ''
            ln -s ${libraries.${d.name}} "$out/${d.name}"
          ''
          + lib.optionalString (rules != [ ]) ''
            ${pkgs.jdk25_headless}/bin/java -cp ${classpath} ${./LuckPermsRelocate.java} ${libraries.${d.name}} "$out/${remapped}" ${
              lib.escapeShellArgs (
                lib.concatMap (r: [
                  (builtins.elemAt r 1)
                  "me.lucko.luckperms.lib.${builtins.elemAt r 0}"
                ]) rules
              )
            }
          ''
        ) definitions
      );
      templates = dir: server: {
        "${dir}/config.yml" = {
          source = toString (
            (pkgs.formats.yaml { }).generate "luckperms-${server}.yml" {
              inherit server;
              storage-method = "postgresql";
              sync-minutes = 1;
              # PostgreSQL is not supported by LuckPerms' SQL message queue.
              messaging-service = "pluginmsg";
              auto-install-translations = false;
              data = {
                address = "127.0.0.1:5432";
                database = "luckperms";
                username = "luckperms";
                password = "@LUCKPERMS_PASSWORD@";
                pool-settings = {
                  maximum-pool-size = 4;
                  minimum-idle = 1;
                  connection-timeout = 5000;
                  properties.sslmode = "disable";
                };
              };
            }
          );
          replacements."@LUCKPERMS_PASSWORD@" = "/run/agenix/${secret}";
        };
        "${dir}/bootstrap.json".source = toString (
          (pkgs.formats.json { }).generate "luckperms-bootstrap.json" {
            metadata = {
              generatedBy = "Nix";
              generatedAt = "declarative";
            };
            groups = {
              default.nodes =
                map
                  (key: {
                    inherit key;
                    value = true;
                  })
                  [
                    "skinsrestorer.command.set"
                    "voicechat.listen"
                    "voicechat.speak"
                    "voicechat.groups"
                  ];
              admin.nodes = [
                {
                  key = "group.default";
                  value = true;
                }
                {
                  key = "*";
                  value = true;
                }
              ];
            };
            tracks = { };
            users = lib.optionalAttrs (cfg.minecraftAdminUuid != null) {
              ${cfg.minecraftAdminUuid} = {
                primaryGroup = "admin";
                nodes = [
                  {
                    key = "group.admin";
                    value = true;
                  }
                ];
              };
            };
          }
        );
      };
      python = pkgs.python3.withPackages (ps: [ ps.psycopg ]);
      provision = pkgs.writeScript "luckperms-provision" ''
        #!${python}/bin/python3
        exec(compile(open("${./luckperms-postgres.py}").read(), "${./luckperms-postgres.py}", "exec"))
      '';
      dump = pkgs.writeScript "luckperms-dump" ''
        #!${pkgs.python3}/bin/python3
        import sys
        sys.argv = [sys.argv[0], "dump", "${config.services.postgresql.package}/bin/pg_dump"]
        exec(compile(open("${./luckperms-postgres.py}").read(), "${./luckperms-postgres.py}", "exec"))
      '';
    in
    {
      options.infra.games.minecraftAdminUuid = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.strMatching "[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"
        );
        default = null;
      };
      config = lib.mkIf (servers != { }) {
        infra.games.minecraftPlugins.backends = lib.mapAttrs (
          id: _:
          {
            inventory = [
              {
                name = "LuckPerms";
                version = "5.5.71";
                installed = ready;
              }
            ];
          }
          // lib.optionalAttrs ready {
            jars.luckperms = cfg.artifacts.games-luckperms-paper;
            templates = templates "/srv/games/minecraft/${id}/plugins/LuckPerms" id;
            secretNames = [ secret ];
            statePaths = [ "/srv/games/minecraft/${id}/plugins/LuckPerms" ];
          }
        ) servers;
        infra.games.minecraftPlugins.proxy = {
          inventory = [
            {
              name = "LuckPerms";
              version = "5.5.71";
              installed = ready;
            }
          ];
        }
        // lib.optionalAttrs ready {
          jars.luckperms = cfg.artifacts.games-luckperms-velocity;
          templates = templates "/srv/games/minecraft/velocity/plugins/luckperms" "velocity";
          secretNames = [ secret ];
        };
        infra.games.artifacts.games-luckperms-libraries = cache;
        services.postgresql = lib.mkIf ready {
          enable = true;
          ensureDatabases = [ "luckperms" ];
          ensureUsers = [
            {
              name = "luckperms";
              ensureDBOwnership = true;
              ensureClauses.login = true;
            }
          ];
          authentication = lib.mkBefore ''
            host luckperms luckperms 127.0.0.1/32 scram-sha-256
            host luckperms luckperms ::1/128 scram-sha-256
          '';
        };
        services.minecraft-servers.servers = lib.mkIf ready (
          lib.mapAttrs (id: _: {
            symlinks."plugins/LuckPerms/libs" = cache;
          }) servers
          // {
            velocity.symlinks."plugins/luckperms/libs" = cache;
          }
        );
        systemd.tmpfiles.rules = lib.optionals ready [ "d /var/backup/games-luckperms 0700 root root -" ];
        infra.backup.srvPaths = lib.optionals ready [
          "/var/backup/games-luckperms"
          "/srv/games/minecraft/velocity/plugins/luckperms"
        ];
        systemd.services = lib.mkIf ready (
          lib.genAttrs (map (id: "minecraft-server-${id}") ([ "velocity" ] ++ lib.attrNames servers)) (_: {
            after = [ "luckperms-provision.service" ];
            requires = [ "luckperms-provision.service" ];
          })
          // {
            luckperms-provision = {
              after = [ "postgresql.service" ];
              requires = [ "postgresql.service" ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                User = "postgres";
                LoadCredential = [ "password:/run/agenix/${secret}" ];
                ExecStart = "${provision} provision";
              };
            };
            restic-backups-srv.serviceConfig.ExecStartPre = lib.mkAfter [ (toString dump) ];
          }
        );
      };
    };
}

{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      secret = "games/minecraft/luckperms-db-password";
      ready = cfg.secretFiles ? ${secret} && builtins.pathExists cfg.secretFiles.${secret};
      # Keep rank colors and prefix priorities together for the chat formatter.
      ranks = {
        default = {
          weight = 0;
        };
        builder = {
          weight = 10;
          prefix = "&6[Builder]&r ";
        };
        mod = {
          weight = 20;
          prefix = "&d[Mod]&r ";
        };
        admin = {
          weight = 30;
          prefix = "&a[Admin]&r ";
        };
      };
      grants = map (key: {
        inherit key;
        value = true;
      });
      rankNodes =
        rank:
        let
          style = ranks.${rank};
        in
        grants (
          [ "weight.${toString style.weight}" ]
          ++ lib.optional (style ? prefix) "prefix.${toString style.weight}.${style.prefix}"
        );
      builderPermissions = [
        "group.default"
        "minecraft.command.gamemode"
        "minecraft.command.gamemode.survival"
        "minecraft.command.gamemode.creative"
        "fawe.limit.builder"
        "fawe.cancel"
        "worldedit.help"
        "worldedit.wand"
        "worldedit.wand.toggle"
        "worldedit.selection.pos"
        "worldedit.selection.hpos"
        "worldedit.selection.chunk"
        "worldedit.selection.expand"
        "worldedit.selection.contract"
        "worldedit.selection.shift"
        "worldedit.selection.outset"
        "worldedit.selection.inset"
        "worldedit.selection.size"
        "worldedit.analysis.sel"
        "worldedit.analysis.count"
        "worldedit.analysis.distr"
        "worldedit.global-mask"
        "worldedit.region.set"
        "worldedit.region.replace"
        "worldedit.region.walls"
        "worldedit.region.faces"
        "worldedit.region.overlay"
        "worldedit.region.center"
        "worldedit.region.hollow"
        "worldedit.region.move"
        "worldedit.region.stack"
        "worldedit.region.smooth"
        "worldedit.region.naturalize"
        "worldedit.region.line"
        "worldedit.region.curve"
        "worldedit.generation.sphere"
        "worldedit.generation.cylinder"
        "worldedit.generation.pyramid"
        "worldedit.clipboard.copy"
        "worldedit.clipboard.cut"
        "worldedit.clipboard.paste"
        "worldedit.clipboard.clear"
        "worldedit.clipboard.rotate"
        "worldedit.clipboard.flip"
        "worldedit.history.undo"
        "worldedit.history.redo"
        "worldedit.brush.sphere"
        "worldedit.brush.cylinder"
        "worldedit.brush.clipboard"
        "worldedit.brush.smooth"
        "worldedit.brush.options.range"
        "worldedit.brush.options.size"
        "worldedit.brush.options.material"
        "worldedit.brush.options.mask"
        "worldedit.tool.none"
        "voxelsniper.sniper"
        "voxelsniper.brush.snipe"
        "voxelsniper.brush.ball"
        "voxelsniper.brush.voxel"
        "voxelsniper.brush.disc"
        "voxelsniper.brush.voxeldisc"
        "voxelsniper.brush.cylinder"
        "voxelsniper.brush.overlay"
        "voxelsniper.brush.underlay"
        "voxelsniper.brush.blendball"
        "voxelsniper.brush.blenddisc"
        "voxelsniper.brush.blendvoxel"
        "voxelsniper.brush.blendvoxeldisc"
        "wesv.use"
        "wesv.toggle"
      ];
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
                    "huskhomes.max_homes.10"
                    "huskhomes.command.home"
                    "huskhomes.command.sethome"
                    "huskhomes.command.delhome"
                    "huskhomes.command.homelist"
                    "huskhomes.command.edithome"
                    "huskhomes.command.edithome.privacy"
                    "huskhomes.command.phome"
                    "huskhomes.command.phomelist"
                    "huskhomes.command.warp"
                    "huskhomes.command.warplist"
                    "huskhomes.command.tpa"
                    "huskhomes.command.tpahere"
                    "huskhomes.command.tpaccept"
                    "huskhomes.command.tpdecline"
                    "huskhomes.command.tpignore"
                    "axgraves.help"
                    "axgraves.list"
                    "axgraves.allowgraves"
                  ]
                ++ rankNodes "default"
                # These visualizer permissions default to true upstream.
                ++
                  map
                    (key: {
                      inherit key;
                      value = false;
                    })
                    [
                      "wesv.use"
                      "wesv.toggle"
                      "wesv.lock"
                    ];
              builder.nodes = grants builderPermissions ++ rankNodes "builder";
              mod.nodes =
                map
                  (key: {
                    inherit key;
                    value = true;
                  })
                  [
                    "group.builder"
                    "minecraft.command.kick"
                    "velocity.command.kick"
                    "huskhomes.command.tp"
                    "minecraft.command.gamemode"
                    "minecraft.command.gamemode.survival"
                    "minecraft.command.gamemode.spectator"
                    "minecraft.command.gamemode.creative"
                    "minecraft.command.gamemode.adventure"
                    "axgraves.list.other"
                    "axgraves.admin"
                  ]
                ++ rankNodes "mod";
              admin.nodes = [
                {
                  key = "group.mod";
                  value = true;
                }
                {
                  key = "*";
                  value = true;
                }
              ]
              ++ rankNodes "admin"
              ++ grants [ "wesv.lock" ];
            };
            tracks.staff.groups = [
              "default"
              "builder"
              "mod"
              "admin"
            ];
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
          lib.mapAttrs (_id: _: {
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
              # Setup creates the role, database, and ownership before provisioning alters the role.
              after = [
                "postgresql.service"
                "postgresql-setup.service"
              ];
              requires = [
                "postgresql.service"
                "postgresql-setup.service"
              ];
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

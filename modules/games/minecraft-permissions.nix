{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      secret = "games/minecraft/luckperms-db-password";
      ready = cfg.secretFiles ? ${secret} && builtins.pathExists cfg.secretFiles.${secret};
      ranks = cfg.minecraftRanks;
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
          [
            "weight.${toString style.weight}"
            "meta.chat_color.<${style.color}>"
          ]
          ++ lib.optional (style ? prefix) "prefix.${toString style.weight}.${style.prefix}"
        );
      polishPermissions = {
        default = [
          "openinv.enderchest.edit.self"
          "openinv.access.online"
          "carbon.channel.global"
          "carbon.channel.global.see"
          "carbon.channel.global.speak"
          "carbon.nickname"
          "carbon.nickname.set"
          "carbon.nickname.tags.color"
          "carbon.nickname.tags.reset"
          "discordsrv.nicknamesync"
        ];
        mod = [
          "openinv.inventory.open.other"
          "openinv.enderchest.open.other"
          "openinv.access.offline"
          "openinv.access.crossworld"
          "openinv.access.level.1"
        ];
      };
      # A specific colour/reset grant overrides the tag wildcard denial.
      # Apply to admin too: the existing * grant must not allow unsafe nicknames.
      nicknameRestrictions =
        map
          (key: {
            inherit key;
            value = false;
          })
          [
            "carbon.nickname.tags.*"
            "carbon.nickname.filter"
          ];
      # Installing PlaceholderAPI must not turn literal Carbon chat into
      # placeholder input, including for admins with the existing * grant.
      chatPlaceholderRestrictions = [
        {
          key = "carbon.chatplaceholders";
          value = false;
        }
      ];
      # Deny each rank explicitly so op defaults and admin's * cannot grant
      # grave teleporting. Leave normal HuskHomes /back permissions alone.
      deathReturnRestrictions =
        map
          (key: {
            inherit key;
            value = false;
          })
          [
            "huskhomes.command.back.death"
            "axgraves.tp"
            "axgraves.tp.bypass"
          ];
      # Announce every rank on Discord, including admins with the * grant.
      joinLeaveRestrictions =
        map
          (key: {
            inherit key;
            value = false;
          })
          [
            "discordsrv.silentjoin"
            "discordsrv.silentquit"
          ];
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
      bootstrap = {
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
                "veinminer.use"
              ]
            ++ grants polishPermissions.default
            ++ nicknameRestrictions
            ++ chatPlaceholderRestrictions
            ++ deathReturnRestrictions
            ++ joinLeaveRestrictions
            ++ [
              {
                key = "carbon.nickname.others.set";
                value = false;
              }
            ]
            ++ rankNodes "default"
            # Visualizer use defaults to true upstream; Veinminer configuration
            # commands must also remain unavailable to ordinary players.
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
                  "veinminer.toggle"
                  "veinminer.blocks"
                  "veinminer.groups"
                  "veinminer.settings"
                  "veinminer.reload"
                ];
          builder.nodes =
            grants builderPermissions
            ++ rankNodes "builder"
            ++ chatPlaceholderRestrictions
            ++ deathReturnRestrictions
            ++ joinLeaveRestrictions;
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
            ++ grants polishPermissions.mod
            ++ rankNodes "mod"
            ++ chatPlaceholderRestrictions
            ++ deathReturnRestrictions
            ++ joinLeaveRestrictions;
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
          ++ nicknameRestrictions
          ++ chatPlaceholderRestrictions
          ++ deathReturnRestrictions
          ++ joinLeaveRestrictions
          ++ grants [
            "carbon.nickname.others.set"
            "carbon.nickname.tags.color"
            "carbon.nickname.tags.reset"
          ]
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
      };
      bootstrapJson = (pkgs.formats.json { }).generate "luckperms-bootstrap.json" bootstrap;
      bootstrapGzip = pkgs.runCommand "luckperms-bootstrap.json.gz" { } ''
        ${pkgs.gzip}/bin/gzip -n -c ${bootstrapJson} > "$out"
      '';
      # ImportCommand merges group/user nodes unless --replace is used, but
      # Importer always replaces tracks and applies supplied primary groups.
      # Import bootstrap.json.gz for fresh data or an intentional replacement.
      # These commands preserve unrelated grants when repairing existing data;
      # check asynchronous results in logs and inspect tracks separately.
      polishCommands =
        lib.concatStringsSep "\n" (
          map (rank: "lp creategroup ${rank}") bootstrap.tracks.staff.groups
          ++ lib.concatMap (
            rank:
            let
              style = ranks.${rank};
              permissions = builtins.filter (
                node:
                !(lib.any (prefix: lib.hasPrefix prefix node.key) [
                  "weight."
                  "meta."
                  "prefix."
                ])
              ) bootstrap.groups.${rank}.nodes;
            in
            [
              "lp group ${rank} setweight ${toString style.weight}"
              "lp group ${rank} meta set chat_color <${style.color}>"
            ]
            ++ lib.optional (
              style ? prefix
            ) "lp group ${rank} meta setprefix ${toString style.weight} ${builtins.toJSON style.prefix}"
            ++ map (
              node:
              if lib.hasPrefix "group." node.key && node.value then
                "lp group ${rank} parent add ${lib.removePrefix "group." node.key}"
              else
                "lp group ${rank} permission set ${node.key} ${lib.boolToString node.value}"
            ) permissions
          ) bootstrap.tracks.staff.groups
          ++ lib.concatMap (uuid: [
            "lp user ${uuid} parent add admin"
            "lp user ${uuid} parent switchprimarygroup admin"
          ]) (lib.attrNames bootstrap.users)
        )
        + "\n";
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
        "${dir}/chat-inventory.commands".source = toString (
          pkgs.writeText "luckperms-chat-inventory.commands" polishCommands
        );
        "${dir}/config.yml" = {
          source = toString (
            (pkgs.formats.yaml { }).generate "luckperms-${server}.yml" {
              inherit server;
              storage-method = "postgresql";
              # TAB's native weight placeholder reads the primary group.
              # Resolve inherited ranks by the same weights as chat metadata.
              primary-group-calculation = "parents-by-weight";
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
        "${dir}/bootstrap.json.gz" = {
          source = toString bootstrapGzip;
          mode = "0600";
        };
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

{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      definitions = builtins.fromJSON (builtins.readFile ./flectonepulse-libraries.json);
      sources = lib.listToAttrs (
        map (
          d:
          lib.nameValuePair d.path (
            pkgs.fetchurl {
              name = builtins.baseNameOf d.path;
              inherit (d) url sha256;
            }
          )
        ) definitions.files
      );
      classpath = lib.concatStringsSep ":" (
        map (path: toString sources.${path}) [
          "org/ow2/asm/asm/9.9/asm-9.9.jar"
          "org/ow2/asm/asm-commons/9.9/asm-commons-9.9.jar"
          "me/lucko/jar-relocator/1.7/jar-relocator-1.7.jar"
        ]
      );
      # Libby checks the original artifact before consulting its relocation cache.
      # Include complete Maven parent/BOM metadata and repository identities so
      # its transitive resolver does not attempt network access at startup.
      cache = pkgs.runCommand "flectonepulse-1.14.0-libraries" { } (
        lib.concatMapStrings (d: ''
          mkdir -p "$out/${builtins.dirOf d.path}"
          ln -s ${sources.${d.path}} "$out/${d.path}"
        '') definitions.files
        + lib.concatMapStrings (path: ''
          ln -s ${pkgs.writeText "flectonepulse-repositories" definitions.metadata.${path}} "$out/${path}"
        '') (lib.attrNames definitions.metadata)
        + lib.concatMapStrings (r: ''
          ${pkgs.jdk25_headless}/bin/java -cp ${classpath} ${./LuckPermsRelocate.java} ${sources.${r.source}} "$out/${r.path}" ${
            lib.escapeShellArgs (
              lib.concatMap (rule: [
                rule.from
                rule.to
              ]) r.rules
            )
          }
        '') definitions.relocations
      );
      configuration =
        invite:
        pkgs.runCommand "flectonepulse-1.14.0-event-config"
          {
            nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ];
          }
          ''
            python3 ${./flectonepulse-config.py} ${cfg.artifacts.games-flectonepulse} ${cfg.artifacts.games-minecraft-client} "$out" ${lib.escapeShellArg invite}
          '';
      files = [
        "config"
        "command"
        "message"
        "permission"
        "integration"
        "localizations/en_us"
      ];
    in
    lib.mkIf (servers != { }) {
      infra.games.artifacts = {
        games-flectonepulse-libraries = cache;
        games-flectonepulse-config = configuration "";
      };
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: s: {
        jars.flectonepulse = cfg.artifacts.games-flectonepulse;
        templates = lib.listToAttrs (
          map (
            file:
            lib.nameValuePair "/srv/games/minecraft/${id}/plugins/FlectonePulse/${file}.yml" {
              source = "${configuration s.minecraft.discord.inviteUrl}/${file}.yml";
            }
          ) files
        );
        statePaths = [ "/srv/games/minecraft/${id}/plugins/FlectonePulse" ];
        inventory = [
          {
            name = "FlectonePulse";
            version = "1.14.0";
            installed = true;
          }
        ];
      }) servers;
      services.minecraft-servers.servers = lib.mapAttrs (_: _: {
        symlinks = {
          "plugins/FlectonePulse/libraries" = cache;
          "plugins/FlectonePulse/minecraft/26.3/lang/en_us.json" =
            "${configuration ""}/minecraft/26.3/lang/en_us.json";
        };
      }) servers;
    };
}

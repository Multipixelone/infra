{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      definitions = builtins.fromJSON (builtins.readFile ./axgraves-libraries.json);
      libraries = lib.listToAttrs (
        map (d: lib.nameValuePair d.name (pkgs.fetchurl { inherit (d) name url sha256; })) definitions
      );
      relocations =
        map
          (from: {
            inherit from;
            to =
              "com.artillexstudios.axgraves.libs.axapi"
              + {
                "org.apache.commons.math3" = ".libs.math3";
                "com.github.benmanes" = ".libs.caffeine";
                "com.artillexstudios.axapi" = "";
              }
              .${from};
          })
          [
            "org.apache.commons.math3"
            "com.github.benmanes"
            "com.artillexstudios.axapi"
          ];
      entry = d: {
        inherit (d) group version classifier;
        artifact-id = d.artifact;
        transitive-dependencies = map entry (
          lib.filter (
            child:
            (
              d.artifact == "caffeine"
              && builtins.elem child.artifact [
                "jspecify"
                "error_prone_annotations"
              ]
            )
          ) definitions
        );
      };
      metadata = (pkgs.formats.yaml { }).generate "axgraves-library-cache.yml" {
        inherit relocations;
        libraries = map entry definitions;
        repositories = [
          "https://repo.artillex-studios.com/releases/"
          "https://repo2.artillex-studios.com/releases/"
          "https://repo1.maven.org/maven2/"
        ];
      };
      classpath = lib.concatStringsSep ":" (
        map (name: toString libraries.${name}) [
          "org.ow2.asm.asm-9.10.1.jar"
          "org.ow2.asm.asm-commons-9.10.1.jar"
          "org.ow2.asm.asm-tree-9.10.1.jar"
          "me.lucko.jar-relocator-1.7.jar"
        ]
      );
      # AxAPI consumes already-relocated jars at these exact cache filenames.
      # Preseed metadata too: missing relocations would invalidate the whole cache.
      cache = pkgs.runCommand "axgraves-1.32.1-libraries" { } (
        ''
          mkdir -p "$out"
          ln -s ${metadata} "$out/cache.yml"
        ''
        + lib.concatMapStrings (d: ''
          ${pkgs.jdk25_headless}/bin/java -cp ${classpath} ${./LuckPermsRelocate.java} ${libraries.${d.name}} "$out/${d.name}" ${
            lib.escapeShellArgs (
              lib.concatMap (r: [
                r.from
                r.to
              ]) relocations
            )
          }
        '') definitions
      );
      configuration = (pkgs.formats.yaml { }).generate "axgraves-1.32.1.yml" {
        prefix = "<gradient:#FF00FF:#DD00FF><b>AxGraves</b></gradient> &7» ";
        despawn-time-seconds = -1;
        grave-limit = -1;
        drop-items = true;
        dropped-item-velocity = true;
        enable-instant-pickup = true;
        instant-pickup-only-own = true;
        interact-only-own = true;
        override-keep-inventory = false;
        override-keep-level = false;
        hologram-height = 0.5;
        head-height = -1.2;
        rotate-head-360 = true;
        auto-rotation = {
          enabled = false;
          speed = 10.0;
        };
        xp-keep-percentage = 1.0;
        store-items = true;
        store-xp = true;
        grave-item-order = [
          "ARMOR"
          "HAND"
          "OFFHAND"
        ];
        auto-equip-armor = true;
        despawn-when-empty = true;
        save-graves = {
          enabled = true;
          auto-save-seconds = 30;
        };
        custom-grave-skull = {
          enabled = false;
          base64 = "";
        };
        spawn-height-limits = {
          world = {
            min = -64;
            max = 319;
          };
          world_nether = {
            min = 0;
            max = 319;
          };
          world_the_end = {
            min = 0;
            max = 319;
          };
        };
        command-aliases = [
          "axgraves"
          "axgrave"
          "graves"
          "grave"
        ];
        world-name = {
          world = "Overworld";
          world_nether = "The Nether";
          world_the_end = "The End";
        };
        disabled-worlds = [ ];
        blacklisted-death-causes = [ ];
        blacklisted-items = { };
        death-listener-priority = "HIGHEST";
        holograms = {
          background-color = "00000000";
          alignment = "center";
          billboard = "vertical";
          see-through = false;
          shadow = true;
        };
        update-notifier = {
          enabled = false;
          on-join = false;
        };
        debug = false;
        version = 19;
      };
    in
    lib.mkIf (servers != { }) {
      infra.games.artifacts.games-axgraves-libraries = cache;
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars.axgraves = cfg.artifacts.games-axgraves;
        templates."/srv/games/minecraft/${id}/plugins/AxGraves/config.yml".source = toString configuration;
        statePaths = [ "/srv/games/minecraft/${id}/plugins/AxGraves" ];
        inventory = [
          {
            name = "AxGraves";
            version = "1.32.1";
            installed = true;
          }
        ];
      }) servers;
      services.minecraft-servers.servers = lib.mapAttrs (_: _: {
        symlinks."plugins/AxAPI/libraries/AxGraves" = cache;
      }) servers;
    };
}

{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      definitions = builtins.fromJSON (builtins.readFile ./huskhomes-libraries.json);
      libraries = map (
        d:
        d
        // {
          source = pkgs.fetchurl {
            name = builtins.baseNameOf d.path;
            inherit (d) url sha256;
          };
        }
      ) definitions;
      # Paper's MavenLibraryResolver uses the server's libraries directory.
      # Include parent/BOM POMs and repository identity, not just driver jars.
      cache = pkgs.runCommand "huskhomes-4.11-9ed80cc-libraries" { } (
        lib.concatMapStrings (d: ''
          mkdir -p "$out/${builtins.dirOf d.path}"
          ln -s ${d.source} "$out/${d.path}"
          echo '${builtins.baseNameOf d.path}>maven=' >> "$out/${builtins.dirOf d.path}/_remote.repositories"
        '') libraries
      );
      configuration = (pkgs.formats.yaml { }).generate "huskhomes-4.11-9ed80cc.yml" {
        language = "en-gb";
        check_for_updates = false;
        database.type = "SQLITE";
        cross_server.enabled = false;
        economy.enabled = false;
        luckperms.enabled = true;
        map_hook = {
          enabled = true;
          show_public_homes = true;
          show_warps = true;
        };
        general = {
          max_homes = 10;
          max_public_homes = 10;
          stack_permission_limits = false;
          # Floodgate usernames start with '.', so avoid the default delimiter.
          home_delimiter = ":";
          teleport_async = true;
          teleport_warmup_time = 5;
          teleport_warmup_cancel_on_damage = true;
          teleport_warmup_cancel_on_move = true;
          teleport_request_expiry_time = 60;
          strict_tpa_here_requests = true;
        };
      };
    in
    lib.mkIf (servers != { }) {
      infra.games.artifacts.games-huskhomes-libraries = cache;
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars.huskhomes = cfg.artifacts.games-huskhomes;
        templates."/srv/games/minecraft/${id}/plugins/HuskHomes/config.yml".source = toString configuration;
        statePaths = [ "/srv/games/minecraft/${id}/plugins/HuskHomes" ];
        inventory = [
          {
            name = "HuskHomes";
            version = "4.11-9ed80cc";
            installed = true;
          }
        ];
      }) servers;
      services.minecraft-servers.servers = lib.mapAttrs (_: _: {
        # Keep Paper's own bundled libraries writable; only plugin artifact
        # directories are immutable, matching the resolver's local repo layout.
        symlinks = lib.listToAttrs (
          map (path: lib.nameValuePair "libraries/${path}" "${cache}/${path}") (
            lib.unique (map (d: builtins.dirOf d.path) definitions)
          )
        );
      }) servers;
    };
}

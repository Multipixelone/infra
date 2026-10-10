{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      definitions = builtins.fromJSON (builtins.readFile ./openinv-libraries.json);
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
      # OpenInv uses Bukkit's Maven loader, sharing Paper's library repository.
      cache = pkgs.runCommand "openinv-5.3.5-libraries" { } (
        lib.concatMapStrings (d: ''
          mkdir -p "$out/${builtins.dirOf d.path}"
          ln -s ${d.source} "$out/${d.path}"
          echo '${builtins.baseNameOf d.path}>central=' >> "$out/${builtins.dirOf d.path}/_remote.repositories"
        '') libraries
      );
      format = pkgs.formats.yaml { };
    in
    lib.mkIf (servers != { }) {
      infra.games.artifacts.games-openinv-libraries = cache;
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars.openinv = cfg.artifacts.games-openinv;
        templates = {
          "/srv/games/minecraft/${id}/plugins/OpenInv/config.yml".source = toString (
            format.generate "openinv-5.3.5.yml" {
              config-version = 8;
              settings = {
                equal-access = "allow";
                # /ec must never reopen the last staff inspection target.
                command.open.no-args-opens-self = true;
                command.searchcontainer.max-radius = 10;
                disable-offline-access = false;
                disable-saving = false;
                console-locale = "en";
              };
            }
          );
          "/srv/games/minecraft/${id}/commands.yml".source = toString (
            format.generate "minecraft-inventory-commands.yml" {
              aliases = {
                invsee = [ "openinv:openinv $1-" ];
                endersee = [ "openinv:openender $1-" ];
                ec = [ "openinv:openender" ];
              };
            }
          );
        };
        statePaths = [ "/srv/games/minecraft/${id}/plugins/OpenInv" ];
        inventory = [
          {
            name = "OpenInv";
            version = "5.3.5";
            installed = true;
          }
        ];
      }) servers;
      services.minecraft-servers.servers = lib.mapAttrs (_: _: {
        symlinks = lib.listToAttrs (
          map (path: lib.nameValuePair "libraries/${path}" "${cache}/${path}") (
            lib.unique (map (d: builtins.dirOf d.path) definitions)
          )
        );
      }) servers;
    };
}

{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      secret = "games/minecraft/luckperms-db-password";
      ready = cfg.secretFiles ? ${secret} && builtins.pathExists cfg.secretFiles.${secret};
      definitions = builtins.fromJSON (builtins.readFile ./carbon-libraries.json);
      libraries = map (d: d // {
        source = pkgs.fetchurl {
          name = builtins.baseNameOf d.path;
          inherit (d) url sha256;
        };
      }) definitions;
      # Gremlin uses fixed jar checksums and does not resolve Maven POMs or
      # relocations for this release. Preserve the exact embedded manifest paths.
      cache = pkgs.runCommand "carbon-3.0.0-beta.39-libraries" { } (
        lib.concatMapStrings (d: ''
          mkdir -p "$out/${builtins.dirOf d.path}"
          ln -s ${d.source} "$out/${d.path}"
        '') libraries
      );
      configuration = pkgs.writeText "carbon-3.0.0-beta.39.conf" ''
        config-version=1
        default-channel="carbon:global"
        storage-type="JSON"
        update-checker=false
        messaging-settings { enabled=false }
        nickname-settings {
          use-carbon-nicknames=false
          update-tab-list=false
        }
        party-chat { enabled=false }
        integrations {
          discordsrv { enabled=true }
          miniplaceholders { relational-placeholders=false }
        }
      '';
      global = pkgs.writeText "carbon-global.conf" ''
        key="carbon:global"
        permission="carbon.channel.global"
        command-name="global"
        command-aliases=[]
        should-register-commands=true
        quick-prefix=""
        radius=-1
        cooldown=-1
        cross-server=false
        format {
          basic {
            default_format="<luckperms_prefix><luckperms_meta:chat_color:s><username><reset> <#a6adc8>›</#a6adc8> <#cdd6f4><message></#cdd6f4>"
            console="[global] <username>: <message>"
            discord="<message>"
          }
          locales={}
        }
      '';
    in
    lib.mkIf (servers != { }) {
      infra.games.artifacts.games-carbon-libraries = cache;
      infra.games.minecraftPlugins.backends = lib.mapAttrs (id: _: {
        jars = lib.optionalAttrs ready {
          carbon = cfg.artifacts.games-carbon;
          miniplaceholders = cfg.artifacts.games-miniplaceholders;
        };
        templates = lib.optionalAttrs ready {
          "/srv/games/minecraft/${id}/plugins/CarbonChat/config.conf".source = toString configuration;
          "/srv/games/minecraft/${id}/plugins/CarbonChat/channels/global.conf".source = toString global;
        };
        statePaths = lib.optionals ready [
          "/srv/games/minecraft/${id}/plugins/CarbonChat"
          "/srv/games/minecraft/${id}/plugins/MiniPlaceholders"
        ];
        inventory = map (d: d // { installed = ready; }) [
          { name = "CarbonChat"; version = "3.0.0-beta.39"; }
          { name = "MiniPlaceholders"; version = "3.2.0"; }
          { name = "MiniPlaceholders LuckPerms Expansion"; version = "2.1.0"; }
        ];
      }) servers;
      services.minecraft-servers.servers = lib.mapAttrs (_: _: {
        symlinks = lib.optionalAttrs ready (
          {
            "plugins/MiniPlaceholders/expansions/LuckPerms-Expansion.jar" = cfg.artifacts.games-miniplaceholders-luckperms;
          }
          # Gremlin writes .last-used.txt siblings on every startup. Keep the
          # parent directories writable; linking the whole cache would fail.
          // lib.listToAttrs (map (d:
            lib.nameValuePair "plugins/CarbonChat/libraries/${d.path}" "${cache}/${d.path}"
          ) definitions)
        );
      }) servers;
    };
}

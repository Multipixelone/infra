{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      ranks = cfg.minecraftRanks;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      secret = "games/minecraft/luckperms-db-password";
      ready = cfg.secretFiles ? ${secret} && builtins.pathExists cfg.secretFiles.${secret};
      format = pkgs.formats.yaml { };
    in
    lib.mkIf (servers != { }) {
      infra.games.minecraftPlugins.backends = lib.mapAttrs (
        id: s:
        {
          inventory = [
            {
              name = "TAB";
              version = "6.2.0";
              installed = ready;
            }
          ];
        }
        // lib.optionalAttrs ready {
          jars.tab = cfg.artifacts.games-tab;
          statePaths = [ "/srv/games/minecraft/${id}/plugins/TAB" ];
          templates = {
            # Share chat's rank colors; keep translatable prefixes live in LP.
            "/srv/games/minecraft/${id}/plugins/TAB/groups.yml".source = toString (
              format.generate "tab-groups.yml" (
                {
                  _DEFAULT_ = {
                    tabprefix = "%luckperms-prefix%";
                    customtabname = "<${ranks.default.color}>%displayname%<reset>";
                    tabsuffix = "";
                    tagprefix = "";
                    tagsuffix = "";
                  };
                }
                // lib.mapAttrs (_: rank: {
                  customtabname = "<${rank.color}>%displayname%<reset>";
                }) ranks
              )
            );
            "/srv/games/minecraft/${id}/plugins/TAB/config.yml".source = toString (
              format.generate "tab-${id}.yml" {
                config-version = 7;
                header-footer = {
                  enabled = true;
                  designs.default = {
                    header = [
                      ""
                      "<gradient:#cba6f7:#f5c2e7:#fab387><bold>Finn's Survival</bold></gradient>"
                      "<#cba6f7>mc.finnrut.is</#cba6f7>"
                      "<#a6adc8>Online <#cdd6f4>%online%/${toString s.minecraft.maxPlayers}</#cdd6f4> · Ping <#cdd6f4>%ping% ms</#cdd6f4></#a6adc8>"
                      ""
                    ];
                    footer = [
                      ""
                      "<#a6adc8>TPS <#cdd6f4>%tps%</#cdd6f4> · MSPT <#cdd6f4>%mspt%</#cdd6f4></#a6adc8>"
                      "<#a6adc8>Map: <#cba6f7>${cfg.runtime.${id}.mapUrl}</#cba6f7></#a6adc8>"
                    ]
                    ++
                      lib.optional (s.minecraft.discord.inviteUrl != "")
                        "<#a6adc8>Discord: <#cba6f7>${lib.removePrefix "https://" s.minecraft.discord.inviteUrl}</#cba6f7></#a6adc8>"
                    ++ [ "" ];
                  };
                };
                tablist-name-formatting = {
                  enabled = true;
                  disable-condition = "";
                };
                # Sorting requires teams or layout. Plain teams keep nametag
                # decoration off; Carbon/FlectonePulse do not manage teams.
                # Client team ownership replaces AFK Display's gray-name effect;
                # it does not alter the datapack's server-side team/detection.
                scoreboard-teams = {
                  enabled = true;
                  enable-collision = true;
                  invisible-nametags = false;
                  can-see-friendly-invisibles = false;
                  disable-condition = "";
                  sorting-types = [
                    "PLACEHOLDER_HIGH_TO_LOW:%luckperms-weight%"
                    "PLACEHOLDER_A_TO_Z:%player%"
                  ];
                  case-sensitive-sorting = false;
                };
                playerlist-objective.enabled = false;
                belowname-objective.enabled = false;
                prevent-spectator-effect.enabled = false;
                bossbar.enabled = false;
                scoreboard.enabled = false;
                layout.enabled = false;
                ping-spoof.enabled = false;
                global-playerlist.enabled = false;
                per-world-playerlist.enabled = false;
                proxy-support.enabled = false;
                mysql.enabled = false;
                assign-groups-by-permissions = false;
                primary-group-finding-list = [ ];
                permission-refresh-interval = 1000;
                placeholders = {
                  date-format = "dd.MM.yyyy";
                  time-format = "HH:mm:ss";
                  time-offset = 0;
                  register-tab-expansion = false;
                  locale = "en-US";
                };
                placeholder-refresh-intervals = {
                  default-refresh-interval = 1000;
                  "%online%" = 1000;
                  "%ping%" = 1000;
                  "%displayname%" = 1000;
                  "%tps%" = 5000;
                  "%mspt%" = 5000;
                  "%luckperms-prefix%" = 1000;
                  "%luckperms-weight%" = 1000;
                };
                placeholder-output-replacements = { };
                conditions = { };
                components = {
                  minimessage-support = true;
                  disable-shadow-for-heads = true;
                };
                use-online-uuid-in-tablist = true;
                compensate-for-packetevents-bug = false;
                debug = false;
                # TAB has no updater/checker flag. Its bStats uses the existing
                # backend plugins/bStats/config.yml with enabled=false.
              }
            );
            "/srv/games/minecraft/${id}/plugins/TAB/users.yml".source = toString (
              format.generate "tab-users.yml" { }
            );
            "/srv/games/minecraft/${id}/plugins/TAB/animations.yml".source = toString (
              format.generate "tab-animations.yml" { }
            );
          };
        }
      ) servers;
    };
}

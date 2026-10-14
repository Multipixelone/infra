{ lib, ... }:
{
  flake.modules.nixos.games-minecraft =
    { config, pkgs, ... }:
    let
      cfg = config.infra.games;
      servers = lib.filterAttrs (_: s: s.game == "minecraft-paper") cfg.servers;
      secret = "games/minecraft/discordsrv-token";
      secretReady = cfg.secretFiles ? ${secret} && builtins.pathExists cfg.secretFiles.${secret};
      ready =
        s:
        s.minecraft.discord.enable
        && secretReady
        && s.minecraft.discord.guildId != ""
        && s.minecraft.discord.channelId != "";
      ownerReady =
        s:
        cfg.minecraftAdminUuid != null
        &&
          lib.length (
            lib.attrNames (lib.filterAttrs (_: uuid: uuid == cfg.minecraftAdminUuid) s.minecraft.whitelist)
          ) == 1;
      accessEnabled = s: ready s && s.minecraft.discord.requireLinkedAccount && ownerReady s;
      roles = s: lib.filterAttrs (_: role: role != "") s.minecraft.discord.roles;
      syncEnabled = s: roles s != { };
      palette = {
        awake = "#a6e3a1";
        starting = "#fab387";
        resting = "#6c7086";
        stopped = "#f38ba8";
        failed = "#f38ba8";
        disabled = "#6c7086";
        join = "#a6e3a1";
        firstJoin = "#cba6f7";
        leave = "#a6adc8";
        death = "#f38ba8";
        advancement = "#f9e2af";
      };
      notifierReady = s: ready s && cfg.observability.inventory != { };
      notifierConfig =
        id: s:
        pkgs.writeText "minecraft-discord-${id}.json" (
          builtins.toJSON {
            serverId = id;
            inherit (s) displayName;
            channelId = s.minecraft.discord.channelId;
            colors = palette;
          }
        );
      notifierPython = pkgs.python3.withPackages (ps: [ ps.prometheus-client ]);
      message = color: author: {
        Enabled = true;
        Content = "";
        Embed = {
          Enabled = true;
          Color = color;
          Author = {
            ImageUrl = "%embedavatarurl%";
            Name = author;
            Url = "";
          };
          ThumbnailUrl = "";
          Title = {
            Text = "";
            Url = "";
          };
          Description = "";
          Fields = [ ];
          ImageUrl = "";
          Footer = {
            Text = "";
            IconUrl = "";
          };
          Timestamp = false;
        };
        Webhook.Enable = false;
      };
      format = pkgs.formats.yaml { };
      tokenPrepare = pkgs.writeScript "minecraft-discord-token-prepare" ''
        #!${pkgs.python3}/bin/python3
        import runpy
        runpy.run_path("${./minecraft-discord-token.py}", run_name="__main__")
      '';
    in
    lib.mkIf (servers != { }) {
      assertions = [
        {
          assertion = lib.all (s: !(s.minecraft.discord.requireLinkedAccount && ready s) || ownerReady s) (
            lib.attrValues servers
          );
          message = "mandatory Discord linking requires exactly one whitelist entry matching Finn's declared Minecraft UUID";
        }
      ];
      infra.games.minecraftPlugins.backends = lib.mapAttrs (
        id: s:
        {
          discordAccessEnabled = accessEnabled s;
          inventory = [
            {
              name = "DiscordSRV";
              version = "1.30.5";
              installed = ready s;
            }
            {
              name = "Vault";
              version = "1.7.3";
              installed = ready s && syncEnabled s;
            }
          ];
        }
        // lib.optionalAttrs (ready s) {
          jars = {
            discordsrv = cfg.artifacts.games-discordsrv;
          }
          // lib.optionalAttrs (syncEnabled s) {
            vault = cfg.artifacts.games-vault;
          };
          secretNames = [ secret ];
          statePaths = [ "/srv/games/minecraft/${id}/plugins/DiscordSRV" ];
          templates =
            lib.mapAttrs'
              (
                name: value:
                lib.nameValuePair "/srv/games/minecraft/${id}/plugins/DiscordSRV/${name}.yml" {
                  source = toString (
                    if name != "config" then
                      format.generate "discordsrv-${id}-${name}.yml" value
                    else
                      let
                        # DiscordSRV uses the first channel as its fallback.
                        # Adding `death` would otherwise sort before `global`.
                        body = format.generate "discordsrv-${id}-config-body.yml" (removeAttrs value [ "Channels" ]);
                        channels = pkgs.writeText "discordsrv-${id}-channels.yml" (
                          "Channels:\n"
                          + lib.concatMapStrings (key: "  ${key}: ${builtins.toJSON value.Channels.${key}}\n") (
                            [ "global" ] ++ lib.attrNames (removeAttrs value.Channels [ "global" ])
                          )
                        );
                      in
                      pkgs.runCommand "discordsrv-${id}-config.yml" { } ''
                        cat ${body} ${channels} > "$out"
                      ''
                  );
                }
              )
              {
                config = {
                  ConfigVersion = "1.30.5";
                  BotToken = "";
                  DiscordInviteLink = s.minecraft.discord.inviteUrl;
                  # 1.30.5 routes these events by Channels keys, not messages.yml fields.
                  # global is rendered first and remains the fallback for joins/leaves/awards/status.
                  Channels = {
                    global = s.minecraft.discord.channelId;
                  }
                  // lib.optionalAttrs (s.minecraft.discord.eventsChannelId != "") {
                    death = s.minecraft.discord.eventsChannelId;
                  };
                  DiscordConsoleChannelId = s.minecraft.discord.consoleChannelId;
                  DiscordConsoleChannelBlacklistActsAsWhitelist = true;
                  DiscordConsoleChannelBlacklistedCommands = [
                    "list"
                    "tps"
                  ];
                  DiscordConsoleChannelBlockBots = true;
                  DiscordConsoleChannelLogRefreshRateInSeconds = 5;
                  DiscordConsoleChannelLevels = [
                    "info"
                    "warn"
                    "error"
                  ];
                  DiscordChatChannelConsoleCommandEnabled = false;
                  DiscordChatChannelRequireLinkedAccount = false;
                  DiscordChatChannelDiscordToMinecraft = true;
                  DiscordChatChannelMinecraftToDiscord = true;
                  DiscordChatChannelAllowedMentions = [ ];
                  DiscordChatChannelBlockBots = true;
                  DiscordChatChannelBlockWebhooks = true;
                  DiscordCannedResponses = { };
                  # Code redemption proves account ownership; linking grants no permissions.
                  MinecraftDiscordAccountLinkedUsePM = true;
                  MinecraftDiscordAccountLinkedAllowRelinkBySendingANewCode = false;
                  MinecraftDiscordAccountLinkedConsoleCommands = [ ];
                  MinecraftDiscordAccountUnlinkedConsoleCommands = [ ];
                  MinecraftDiscordAccountLinkedRoleNameToAddUserTo = "";
                  # The default file backend keeps accounts.aof in the backed-up plugin directory.
                  Experiment_JdbcAccountLinkBackend = "";
                  UseModernPaperChatEvent = true;
                  EnablePresenceInformation = false;
                  DiscordGameStatus = "playing mc.finnrut.is";
                  Experiment_WebhookChatMessageDelivery = true;
                  Experiment_WebhookChatMessageUsernameFormat = "%displayname%";
                  Experiment_WebhookChatMessageFormat = "%message%";
                  Experiment_WebhookChatMessageUsernameFromDiscord = false;
                  Experiment_WebhookChatMessageAvatarFromDiscord = false;
                  AvatarUrl = "";
                  ServerWatchdogEnabled = false;
                  ChannelTopicUpdaterRateInMinutes = 0;
                  ChannelTopicUpdaterChannelTopicsAtShutdownEnabled = false;
                };
                messages = {
                  # %name% is the Discord server nickname, including the Carbon
                  # name maintained by nickname synchronization for linked users.
                  # Keep Discord roles in hover text rather than staff rank badges.
                  DiscordToMinecraftChatMessageFormat = "<white><hover:show_text:'Discord'>[Discord]</hover></white> <#cba6f7><hover:show_text:'Discord role: %toprole%'>%name%</hover></#cba6f7>%reply% <#a6adc8>›</#a6adc8> <#cdd6f4>%message%</#cdd6f4>";
                  DiscordToMinecraftChatMessageFormatNoRole = "<white><hover:show_text:'Discord'>[Discord]</hover></white> <#cba6f7>%name%</#cba6f7>%reply% <#a6adc8>›</#a6adc8> <#cdd6f4>%message%</#cdd6f4>";
                  DiscordToMinecraftMessageReplyFormat = " <#a6adc8>(replying to %name%)</#a6adc8>";
                  # Rank prefixes are MiniMessage on Minecraft. Do not pass them
                  # through Vault's legacy string path into Discord messages.
                  # Carbon beta.39 writes its nickname to the Bukkit display name
                  # and passes the Bukkit player to DiscordSRV's native chat path.
                  # DiscordSRV also reads it for events (joins wait 20 ticks).
                  MinecraftChatToDiscordMessageFormat = "%displayname% › %message%";
                  MinecraftChatToDiscordMessageFormatNoPrimaryGroup = "%displayname% › %message%";
                  MinecraftPlayerJoinMessage = message palette.join "%displayname% joined ${s.displayName}";
                  MinecraftPlayerFirstJoinMessage = message palette.firstJoin "%displayname% joined ${s.displayName} for the first time";
                  MinecraftPlayerLeaveMessage = message palette.leave "%displayname% left ${s.displayName}";
                  # The death narrative retains account names and the full cause.
                  MinecraftPlayerDeathMessage = message palette.death "%deathmessage%";
                  MinecraftPlayerAchievementMessage = message palette.advancement "%displayname% earned %achievement%";
                  # These are plain strings in 1.30.5 and fire for every Paper cycle.
                  # The independent notifier owns the coalesced status embed instead.
                  DiscordChatChannelServerStartupMessage = "";
                  DiscordChatChannelServerShutdownMessage = "";
                };
                synchronization = {
                  # 1.30.5 strips display-name colours and clamps polling to >= 3 minutes.
                  # Without a Carbon nickname, this sets the MC account name on Discord.
                  NicknameSynchronizationEnabled = true;
                  NicknameSynchronizationCycleTime = 3;
                  NicknameSynchronizationFormat = "%displayname%";
                  GroupRoleSynchronizationGroupsAndRolesToSync = roles s;
                  # Both keys are required: authoritative alone still permits reverse sync events.
                  GroupRoleSynchronizationMinecraftIsAuthoritative = true;
                  GroupRoleSynchronizationOneWay = true;
                  GroupRoleSynchronizationPrimaryGroupOnly = false;
                  GroupRoleSynchronizationEnableDenyPermission = false;
                  GroupRoleSynchronizationOnLink = syncEnabled s;
                  # An empty mapping disables sync; 1.30.5 clamps cycle times to >= 1 minute.
                  GroupRoleSynchronizationCycleTime = 5;
                  GroupRoleSynchronizationCycleCompletely = false;
                  BanSynchronizationDiscordToMinecraft = false;
                  BanSynchronizationMinecraftToDiscord = false;
                };
                linking."Require linked account to play" = {
                  Enabled = accessEnabled s;
                  "Listener event" = "AsyncPlayerPreLoginEvent";
                  "Listener priority" = "LOWEST";
                  "Bypass names" = [ ];
                  # The generated whitelist contains only Finn while this gate is enabled.
                  # 1.30.5 compares these UUIDs even when white-list=false.
                  "Whitelisted players bypass check" = accessEnabled s;
                  "Check banned players" = false;
                  "Only check banned players" = false;
                  "Must be in Discord server" = s.minecraft.discord.guildId;
                  "Subscriber role" = {
                    "Require subscriber role to join" = false;
                    "Subscriber roles" = [ ];
                    "Require all of the listed roles" = false;
                  };
                  "Not linked message" = "&7DM &b{BOT} &7the code &b{CODE} &7to join.";
                  Messages = {
                    "DiscordSRV still starting" =
                      "&7Survival is connecting to Discord. Please try joining again in a minute.";
                    "Not in server" = "&7Your linked Discord account must be in Finn's Discord server.";
                    "Failed for unknown reason" = "&7Couldn't verify Discord access. Try again or ask Finn.";
                    "Kicked for unlinking" =
                      "&7Your Minecraft and Discord accounts were unlinked.\n&7Rejoin Minecraft to get a new code to DM the bot.";
                  };
                };
                voice.Enabled = false;
              }
            // lib.optionalAttrs (syncEnabled s) {
              "/srv/games/minecraft/${id}/plugins/Vault/config.yml".source = toString (
                format.generate "vault-${id}-config.yml" { update-check = false; }
              );
            };
        }
      ) servers;
      systemd.services =
        lib.mapAttrs' (
          id: s:
          lib.nameValuePair "minecraft-server-${id}" {
            serviceConfig.ExecStartPre = lib.mkIf (ready s) (
              # games-prepare has mkAfter priority 1500; trim after its private configs.
              lib.mkOrder 1600 [
                "+${tokenPrepare} /run/agenix/${secret} /srv/games/minecraft/${id}/plugins/DiscordSRV/.token"
              ]
            );
          }
        ) servers
        // lib.mapAttrs' (
          id: s:
          lib.nameValuePair "minecraft-discord-${id}" {
            description = "Coalesce ${s.displayName} Discord lifecycle status";
            after = [
              "agenix.service"
              "games-metrics.service"
              "network-online.target"
            ];
            wants = [ "network-online.target" ];
            serviceConfig = {
              Type = "oneshot";
              DynamicUser = true;
              StateDirectory = "minecraft-discord-${id}";
              StateDirectoryMode = "0700";
              UMask = "0077";
              LoadCredential = [ "discord-token:/run/agenix/${secret}" ];
              ExecStart = "${notifierPython}/bin/python3 ${./minecraft-discord-status.py} --config ${notifierConfig id s}";
              TimeoutStartSec = "45s";
              NoNewPrivileges = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateTmp = true;
              PrivateDevices = true;
              RestrictAddressFamilies = [
                "AF_INET"
                "AF_INET6"
              ];
            };
          }
        ) (lib.filterAttrs (_: notifierReady) servers);
      systemd.timers = lib.mapAttrs' (
        id: _:
        lib.nameValuePair "minecraft-discord-${id}" {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "60s";
            OnUnitInactiveSec = "30s";
            AccuracySec = "1s";
          };
        }
      ) (lib.filterAttrs (_: notifierReady) servers);
    };
}

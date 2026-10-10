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
      roles = s: lib.filterAttrs (_: role: role != "") s.minecraft.discord.roles;
      syncEnabled = s: roles s != { };
      message = content: {
        Enabled = true;
        Content = content;
        Embed.Enabled = false;
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
      infra.games.minecraftPlugins.backends = lib.mapAttrs (
        id: s:
        {
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
                        body = format.generate "discordsrv-${id}-config-body.yml" (
                          builtins.removeAttrs value [ "Channels" ]
                        );
                        channels = pkgs.writeText "discordsrv-${id}-channels.yml" (
                          "Channels:\n"
                          + lib.concatMapStrings (key: "  ${key}: ${builtins.toJSON value.Channels.${key}}\n") (
                            [ "global" ] ++ lib.attrNames (builtins.removeAttrs value.Channels [ "global" ])
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
                  # 1.30.5 routes these events by Channels keys, not messages.yml fields.
                  # global is rendered first and remains the fallback for awards/status.
                  Channels = {
                    global = s.minecraft.discord.channelId;
                  }
                  // lib.optionalAttrs (s.minecraft.discord.eventsChannelId != "") {
                    join = s.minecraft.discord.eventsChannelId;
                    leave = s.minecraft.discord.eventsChannelId;
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
                  Experiment_WebhookChatMessageDelivery = false;
                  ServerWatchdogEnabled = false;
                  ChannelTopicUpdaterRateInMinutes = 0;
                  ChannelTopicUpdaterChannelTopicsAtShutdownEnabled = false;
                };
                messages = {
                  # Rank prefixes are MiniMessage on Minecraft. Do not pass them
                  # through Vault's legacy string path into Discord messages.
                  MinecraftChatToDiscordMessageFormat = "%username% › %message%";
                  MinecraftChatToDiscordMessageFormatNoPrimaryGroup = "%username% › %message%";
                  MinecraftPlayerJoinMessage = message "%username% joined Survival";
                  MinecraftPlayerFirstJoinMessage = message "%username% joined Survival for the first time";
                  MinecraftPlayerLeaveMessage = message "%username% left Survival";
                  MinecraftPlayerDeathMessage = message "%deathmessage%";
                  MinecraftPlayerAchievementMessage = message "%username% earned %achievement%";
                  DiscordChatChannelServerStartupMessage = "Survival is awake.";
                  DiscordChatChannelServerShutdownMessage = "Survival is resting; join Minecraft to wake it.";
                };
                synchronization = {
                  NicknameSynchronizationEnabled = false;
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
                linking."Require linked account to play".Enabled = false;
                voice.Enabled = false;
              }
            // lib.optionalAttrs (syncEnabled s) {
              "/srv/games/minecraft/${id}/plugins/Vault/config.yml".source = toString (
                format.generate "vault-${id}-config.yml" { update-check = false; }
              );
            };
        }
      ) servers;
      systemd.services = lib.mapAttrs' (
        id: s:
        lib.nameValuePair "minecraft-server-${id}" {
          serviceConfig.ExecStartPre = lib.mkIf (ready s) (
            # games-prepare has mkAfter priority 1500; trim after its private configs.
            lib.mkOrder 1600 [
              "+${tokenPrepare} /run/agenix/${secret} /srv/games/minecraft/${id}/plugins/DiscordSRV/.token"
            ]
          );
        }
      ) servers;
    };
}

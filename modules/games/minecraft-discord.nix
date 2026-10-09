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
      message = content: {
        Enabled = true;
        Content = content;
        Embed.Enabled = false;
        Webhook.Enable = false;
      };
      format = pkgs.formats.yaml { };
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
          ];
        }
        // lib.optionalAttrs (ready s) {
          jars.discordsrv = cfg.artifacts.games-discordsrv;
          secretNames = [ secret ];
          statePaths = [ "/srv/games/minecraft/${id}/plugins/DiscordSRV" ];
          templates = {
            # Tokens contain periods, unlike games-prepare's password placeholders.
            "/srv/games/minecraft/${id}/plugins/DiscordSRV/.token".secret = "/run/agenix/${secret}";
          }
          //
            lib.mapAttrs'
              (
                name: value:
                lib.nameValuePair "/srv/games/minecraft/${id}/plugins/DiscordSRV/${name}.yml" {
                  source = toString (format.generate "discordsrv-${id}-${name}.yml" value);
                }
              )
              {
                config = {
                  ConfigVersion = "1.30.5";
                  BotToken = "";
                  Channels.global = s.minecraft.discord.channelId;
                  DiscordConsoleChannelId = "";
                  DiscordChatChannelConsoleCommandEnabled = false;
                  DiscordChatChannelRequireLinkedAccount = false;
                  DiscordChatChannelDiscordToMinecraft = true;
                  DiscordChatChannelMinecraftToDiscord = true;
                  DiscordChatChannelAllowedMentions = [ ];
                  DiscordChatChannelBlockBots = true;
                  DiscordChatChannelBlockWebhooks = true;
                  DiscordCannedResponses = { };
                  UseModernPaperChatEvent = true;
                  EnablePresenceInformation = false;
                  Experiment_WebhookChatMessageDelivery = false;
                  ServerWatchdogEnabled = false;
                  ChannelTopicUpdaterRateInMinutes = 0;
                  ChannelTopicUpdaterChannelTopicsAtShutdownEnabled = false;
                };
                messages = {
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
                  GroupRoleSynchronizationGroupsAndRolesToSync = { };
                  GroupRoleSynchronizationOnLink = false;
                  BanSynchronizationDiscordToMinecraft = false;
                  BanSynchronizationMinecraftToDiscord = false;
                };
                linking."Require linked account to play".Enabled = false;
                voice.Enabled = false;
              };
        }
      ) servers;
    };
}

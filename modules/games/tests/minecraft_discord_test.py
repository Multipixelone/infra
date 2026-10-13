"""Validate generated DiscordSRV configuration against the exact pinned jar."""

import json
import pathlib
import re
import sys
import zipfile

import yaml

cases = json.loads(pathlib.Path(sys.argv[1]).read_text())
with zipfile.ZipFile(sys.argv[2]) as jar:
    descriptor = yaml.safe_load(jar.read("plugin.yml"))
    discord_defaults = yaml.safe_load(jar.read("config/en.yml"))
    message_defaults = yaml.safe_load(jar.read("messages/en.yml"))
    synchronization_defaults = yaml.safe_load(jar.read("synchronization/en.yml"))
    linking_defaults = yaml.safe_load(jar.read("linking/en.yml"))
assert discord_defaults["ConfigVersion"] == "1.30.5"


def supported(value, defaults, path=""):
    if path == "DiscordGameStatus":
        assert isinstance(value, (str, list))
    elif path == "Require linked account to play.Must be in Discord server":
        # The pinned resource documents bool, guild ID string and guild ID list.
        assert isinstance(value, (bool, str, list)), path
    elif isinstance(value, dict):
        assert isinstance(defaults, dict), path
        if path in ("Channels", "GroupRoleSynchronizationGroupsAndRolesToSync"):
            assert all(isinstance(item, str) for item in value.values()), path
            return
        assert value.keys() <= defaults.keys(), path
        for key, child in value.items():
            supported(child, defaults[key], f"{path}.{key}" if path else key)
    else:
        assert type(value) is type(defaults), path


for case in cases:
    assert case["installed"] == case["expected"]
    access_expected = (
        case["expected"]
        and case["discord"]["requireLinkedAccount"]
        and case["ownerExpected"]
    )
    assert case["accessEnabled"] == access_expected
    assert case["ownerAssertion"] == (
        not (case["expected"] and case["discord"]["requireLinkedAccount"])
        or case["ownerExpected"]
    )
    properties = dict(
        line.split("=", 1)
        for line in pathlib.Path(case["properties"]).read_text().splitlines()
        if "=" in line
    )
    for key in ("white-list", "enforce-whitelist"):
        assert properties[key] == ("false" if access_expected else "true")
    whitelist = json.loads(pathlib.Path(case["whitelist"]).read_text())
    if access_expected:
        assert whitelist == [
            {"name": "Tunnelmaker", "uuid": "3f771d00-3456-4007-8d66-13fe158488fa"}
        ]
        assert whitelist[0]["uuid"] == case["ownerUuid"]
    else:
        assert {entry["name"]: entry["uuid"] for entry in whitelist} == case[
            "configuredWhitelist"
        ]
    floodgate = yaml.safe_load(pathlib.Path(case["floodgateConfiguration"]).read_text())
    assert floodgate["player-link"]["enabled"] is True
    assert floodgate["player-link"]["enable-global-linking"] is True
    assert floodgate["player-link"]["require-link"] is False
    assert floodgate["player-link"]["enable-own-linking"] is False
    assert floodgate["username-prefix"] == "."
    assert floodgate["send-floodgate-data"] is False
    mappings = {group: role for group, role in case["discord"]["roles"].items() if role}
    assert case["vaultInstalled"] == (case["expected"] and bool(mappings))
    assert not case[
        "baseAvailable"
    ]  # No mandatory Minecraft credentials in these fixtures.
    assert (
        case["tokenCopy"] is None
    )  # Text-only preparation is outside generic raw-byte copying.
    token_hooks = [
        entry
        for entry in case["preStart"]
        if "minecraft-discord-token-prepare" in entry
    ]
    if case["expected"]:
        assert len(token_hooks) == 1
        assert token_hooks[0].startswith("+")
        assert token_hooks[0].endswith(
            " /run/agenix/games/minecraft/discordsrv-token /srv/games/minecraft/survival/plugins/DiscordSRV/.token"
        )
        prepare_index = next(
            i for i, entry in enumerate(case["preStart"]) if "games-prepare" in entry
        )
        assert prepare_index < case["preStart"].index(token_hooks[0])
        assert case["declaredSecret"] == "0400"
        assert any(path.endswith("plugins/DiscordSRV") for path in case["statePaths"])
        configuration = yaml.safe_load(pathlib.Path(case["configuration"]).read_text())
        messages = yaml.safe_load(pathlib.Path(case["messages"]).read_text())
        assert configuration.keys() <= discord_defaults.keys()
        assert configuration["DiscordInviteLink"] == case["discord"]["inviteUrl"]
        assert descriptor["commands"]["discord"]["permission"] == "discordsrv.discord"
        supported(configuration, discord_defaults)
        supported(messages, message_defaults)
        assert configuration["BotToken"] == ""
        assert configuration["DiscordGameStatus"] == "playing mc.finnrut.is"
        assert configuration["EnablePresenceInformation"] is False
        assert configuration["Experiment_WebhookChatMessageDelivery"] is True
        assert (
            configuration["Experiment_WebhookChatMessageUsernameFormat"] == "%username%"
        )
        assert configuration["Experiment_WebhookChatMessageFormat"] == "%message%"
        # Rank components belong only to Minecraft recipient formatting.
        for value in [
            configuration["Experiment_WebhookChatMessageUsernameFormat"],
            configuration["Experiment_WebhookChatMessageFormat"],
            *messages.values(),
        ]:
            if isinstance(value, str):
                assert "infra.rank." not in value and "%prefix%" not in value
                assert not any(
                    0xE000 <= ord(character) <= 0xF8FF for character in value
                )
        assert (
            configuration["Experiment_WebhookChatMessageUsernameFromDiscord"] is False
        )
        assert configuration["Experiment_WebhookChatMessageAvatarFromDiscord"] is False
        assert configuration["AvatarUrl"] == ""
        assert configuration["DiscordChatChannelAllowedMentions"] == []
        assert configuration["DiscordChatChannelBlockBots"] is True
        assert configuration["DiscordChatChannelBlockWebhooks"] is True
        assert messages["DiscordChatChannelServerStartupMessage"] == ""
        assert messages["DiscordChatChannelServerShutdownMessage"] == ""
        if case["notifierExpected"]:
            notifier = case["notifier"]["service"]
            assert notifier["DynamicUser"] is True
            assert notifier["StateDirectoryMode"] == "0700"
            assert notifier["LoadCredential"] == [
                "discord-token:/run/agenix/games/minecraft/discordsrv-token"
            ]
            assert notifier["ProtectSystem"] == "strict"
            assert "runtime.py" not in notifier["ExecStart"]
            notifier_config = json.loads(
                pathlib.Path(notifier["ExecStart"].split()[-1]).read_text()
            )
            assert notifier_config["channelId"] == case["discord"]["channelId"]
            assert notifier_config["serverId"] == "survival"
            assert notifier_config["displayName"] == "Survival"
            assert "token" not in notifier_config
            assert case["notifier"]["timer"]["OnUnitInactiveSec"] == "30s"
        else:
            assert case["notifier"] is None
        synchronization = yaml.safe_load(
            pathlib.Path(case["synchronization"]).read_text()
        )
        linking = yaml.safe_load(pathlib.Path(case["linking"]).read_text())
        assert synchronization.keys() <= synchronization_defaults.keys()
        supported(synchronization, synchronization_defaults)
        supported(linking, linking_defaults)
        assert (
            synchronization["GroupRoleSynchronizationGroupsAndRolesToSync"] == mappings
        )
        assert "default" not in mappings
        assert (
            synchronization["GroupRoleSynchronizationMinecraftIsAuthoritative"] is True
        )
        assert synchronization["GroupRoleSynchronizationOneWay"] is True
        assert synchronization["GroupRoleSynchronizationPrimaryGroupOnly"] is False
        assert synchronization["GroupRoleSynchronizationEnableDenyPermission"] is False
        assert synchronization["GroupRoleSynchronizationOnLink"] == bool(mappings)
        assert synchronization["GroupRoleSynchronizationCycleTime"] == 5
        assert synchronization["GroupRoleSynchronizationCycleCompletely"] is False
        assert synchronization["NicknameSynchronizationEnabled"] is False
        assert synchronization["BanSynchronizationDiscordToMinecraft"] is False
        assert synchronization["BanSynchronizationMinecraftToDiscord"] is False
        gate = linking["Require linked account to play"]
        assert gate["Enabled"] == access_expected
        assert gate["Listener event"] == "AsyncPlayerPreLoginEvent"
        assert gate["Listener priority"] == "LOWEST"
        assert gate["Must be in Discord server"] == case["discord"]["guildId"]
        assert isinstance(gate["Must be in Discord server"], str)
        assert gate["Bypass names"] == []
        assert gate["Whitelisted players bypass check"] == access_expected
        assert gate["Check banned players"] is False
        assert gate["Only check banned players"] is False
        assert gate["Subscriber role"]["Require subscriber role to join"] is False
        assert gate["Subscriber role"]["Subscriber roles"] == []
        kick = gate["Not linked message"]
        assert set(re.findall(r"\{([A-Z]+)\}", kick)) == {"BOT", "CODE"}
        assert kick == "&7DM &b{BOT} &7the code &b{CODE} &7to join."
        failures = gate["Messages"]
        assert "minute" in failures["DiscordSRV still starting"]
        assert "new code to DM the bot" in failures["Kicked for unlinking"]
        assert failures["Not in server"] == (
            "&7Your linked Discord account must be in Finn's Discord server."
        )
        assert failures["Failed for unknown reason"] == (
            "&7Couldn't verify Discord access. Try again or ask Finn."
        )
        for value in (
            kick,
            failures["Not in server"],
            failures["Failed for unknown reason"],
        ):
            assert "\n" not in value
        for value in (kick, *failures.values()):
            assert "{INVITE}" not in value
            assert "discord.gg/" not in value and "discord.com/invite/" not in value
            if case["discord"]["inviteUrl"]:
                assert case["discord"]["inviteUrl"] not in value
        for value in failures.values():
            assert not re.findall(r"\{([A-Z]+)\}", value)
        assert configuration["DiscordChatChannelRequireLinkedAccount"] is False
        assert configuration["MinecraftDiscordAccountLinkedUsePM"] is True
        assert (
            configuration["MinecraftDiscordAccountLinkedAllowRelinkBySendingANewCode"]
            is False
        )
        assert configuration["MinecraftDiscordAccountLinkedConsoleCommands"] == []
        assert configuration["MinecraftDiscordAccountUnlinkedConsoleCommands"] == []
        assert configuration["MinecraftDiscordAccountLinkedRoleNameToAddUserTo"] == ""
        assert configuration["Experiment_JdbcAccountLinkBackend"] == ""
        # Existing in-game Discord chat uses the Discord role's configured colour.
        assert (
            "%toprolecolor%" in message_defaults["DiscordToMinecraftChatMessageFormat"]
        )
        if mappings:
            vault_config = yaml.safe_load(
                pathlib.Path(case["vaultConfiguration"]).read_text()
            )
            assert vault_config == {"update-check": False}
        else:
            assert case["vaultConfiguration"] is None
        channels = {"global": case["discord"]["channelId"]}
        if case["discord"]["eventsChannelId"]:
            channels.update(
                death=case["discord"]["eventsChannelId"],
            )
        assert configuration["Channels"] == channels
        assert next(iter(configuration["Channels"])) == "global"
        for key in (
            "MinecraftChatToDiscordMessageFormat",
            "MinecraftChatToDiscordMessageFormatNoPrimaryGroup",
        ):
            assert messages[key] == "%username% › %message%"
        assert (
            configuration["DiscordConsoleChannelId"]
            == case["discord"]["consoleChannelId"]
        )
        assert configuration["DiscordConsoleChannelBlacklistActsAsWhitelist"] is True
        assert configuration["DiscordConsoleChannelBlacklistedCommands"] == [
            "list",
            "tps",
        ]
        assert configuration["DiscordConsoleChannelBlockBots"] is True
        assert not configuration["DiscordChatChannelConsoleCommandEnabled"]
        assert configuration["DiscordConsoleChannelLogRefreshRateInSeconds"] == 5
        assert configuration["DiscordConsoleChannelLevels"] == ["info", "warn", "error"]
        event_colors = {
            "Join": "#a6e3a1",
            "FirstJoin": "#cba6f7",
            "Leave": "#a6adc8",
            "Death": "#f38ba8",
            "Achievement": "#f9e2af",
        }
        for event, color in event_colors.items():
            message = messages[f"MinecraftPlayer{event}Message"]
            assert message["Enabled"]
            assert "Channel" not in message
            assert message["Content"] == ""
            assert message["Webhook"]["Enable"] is False
            embed = message["Embed"]
            assert embed["Enabled"] is True
            assert embed["Color"] == color
            assert embed["Author"]["ImageUrl"] == "%embedavatarurl%"
            assert embed["Author"]["Name"]
            assert embed["Author"]["Url"] == ""
            assert embed["Title"] == {"Text": "", "Url": ""}
            assert embed["Footer"] == {"Text": "", "IconUrl": ""}
            assert embed["Fields"] == []
            assert embed["Timestamp"] is False
            assert all(
                embed[key] == "" for key in ("Description", "ThumbnailUrl", "ImageUrl")
            )
    else:
        assert case["notifier"] is None
        assert case["configuration"] is None
        assert case["synchronization"] is None
        assert case["linking"] is None
        assert case["vaultConfiguration"] is None
        assert token_hooks == []
        assert not any(
            path.endswith("plugins/DiscordSRV") for path in case["statePaths"]
        )


print(
    "PASS: pinned DiscordSRV schema, mandatory linking, guild, owner whitelist, "
    "kick placeholders, Floodgate, styling, credentials and notifier gating"
)

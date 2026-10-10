"""Optional credentials must not disable Minecraft; static maps survive sleep."""

import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

import yaml

cases = json.loads(pathlib.Path(sys.argv[1]).read_text())
with zipfile.ZipFile(sys.argv[6]) as jar:
    discord_defaults = yaml.safe_load(jar.read("config/en.yml"))
    message_defaults = yaml.safe_load(jar.read("messages/en.yml"))
    synchronization_defaults = yaml.safe_load(jar.read("synchronization/en.yml"))
    linking_defaults = yaml.safe_load(jar.read("linking/en.yml"))
assert discord_defaults["ConfigVersion"] == "1.30.5"
for case in cases:
    assert case["installed"] == case["expected"]
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
        assert messages.keys() <= message_defaults.keys()
        synchronization = yaml.safe_load(pathlib.Path(case["synchronization"]).read_text())
        linking = yaml.safe_load(pathlib.Path(case["linking"]).read_text())
        assert synchronization.keys() <= synchronization_defaults.keys()
        assert linking.keys() <= linking_defaults.keys()
        assert synchronization["GroupRoleSynchronizationGroupsAndRolesToSync"] == mappings
        assert "default" not in mappings
        assert synchronization["GroupRoleSynchronizationMinecraftIsAuthoritative"] is True
        assert synchronization["GroupRoleSynchronizationOneWay"] is True
        assert synchronization["GroupRoleSynchronizationPrimaryGroupOnly"] is False
        assert synchronization["GroupRoleSynchronizationEnableDenyPermission"] is False
        assert synchronization["GroupRoleSynchronizationOnLink"] == bool(mappings)
        assert synchronization["GroupRoleSynchronizationCycleTime"] == 5
        assert synchronization["GroupRoleSynchronizationCycleCompletely"] is False
        assert synchronization["NicknameSynchronizationEnabled"] is False
        assert synchronization["BanSynchronizationDiscordToMinecraft"] is False
        assert synchronization["BanSynchronizationMinecraftToDiscord"] is False
        assert linking["Require linked account to play"]["Enabled"] is False
        assert configuration["DiscordChatChannelRequireLinkedAccount"] is False
        assert configuration["MinecraftDiscordAccountLinkedUsePM"] is True
        assert configuration["MinecraftDiscordAccountLinkedAllowRelinkBySendingANewCode"] is False
        assert configuration["MinecraftDiscordAccountLinkedConsoleCommands"] == []
        assert configuration["MinecraftDiscordAccountUnlinkedConsoleCommands"] == []
        assert configuration["MinecraftDiscordAccountLinkedRoleNameToAddUserTo"] == ""
        assert configuration["Experiment_JdbcAccountLinkBackend"] == ""
        # Existing in-game Discord chat uses the Discord role's configured colour.
        assert "%toprolecolor%" in message_defaults["DiscordToMinecraftChatMessageFormat"]
        if mappings:
            vault_config = yaml.safe_load(pathlib.Path(case["vaultConfiguration"]).read_text())
            assert vault_config == {"update-check": False}
        else:
            assert case["vaultConfiguration"] is None
        channels = {"global": case["discord"]["channelId"]}
        if case["discord"]["eventsChannelId"]:
            channels.update(
                join=case["discord"]["eventsChannelId"],
                leave=case["discord"]["eventsChannelId"],
            )
        assert configuration["Channels"] == channels
        assert next(iter(configuration["Channels"])) == "global"
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
        for event in ("Join", "FirstJoin", "Leave", "Death", "Achievement"):
            assert messages[f"MinecraftPlayer{event}Message"]["Enabled"]
            assert "Channel" not in messages[f"MinecraftPlayer{event}Message"]
    else:
        assert case["configuration"] is None
        assert case["synchronization"] is None
        assert case["linking"] is None
        assert case["vaultConfiguration"] is None
        assert token_hooks == []
        assert not any(
            path.endswith("plugins/DiscordSRV") for path in case["statePaths"]
        )
    assert any(path.endswith("plugins/BlueMap") for path in case["statePaths"])
    assert any(path.endswith("plugins/SkinsRestorer") for path in case["statePaths"])

with zipfile.ZipFile(sys.argv[3]) as jar:
    assert "libraries:" not in jar.read("plugin.yml").decode()
    assert "com/flowpowered/math/vector/Vector3d.class" in jar.namelist()
cache = pathlib.Path(sys.argv[4])
assert (cache / "postgresql-driver-42.7.6.jar").exists()
with zipfile.ZipFile(cache / "postgresql-driver-42.7.6-remapped.jar") as jar:
    assert "me/lucko/luckperms/lib/postgresql/Driver.class" in jar.namelist()

permissions = json.loads(pathlib.Path(sys.argv[5]).read_text())
assert permissions["proxyInstalled"] and permissions["backendInstalled"]
assert not permissions["baseAvailable"]
assert "luckperms" in permissions["databases"]
assert permissions["role"]["ensureDBOwnership"]
assert permissions["role"]["ensureClauses"]["login"]
assert (
    "host luckperms luckperms 127.0.0.1/32 scram-sha-256"
    in permissions["authentication"]
)
assert "host luckperms luckperms ::1/128 scram-sha-256" in permissions["authentication"]
assert permissions["secret"] == {
    "owner": "minecraft",
    "group": "minecraft",
    "mode": "0400",
}
assert permissions["provision"]["User"] == "postgres"
assert permissions["provision"]["LoadCredential"] == [
    "password:/run/agenix/games/minecraft/luckperms-db-password"
]
for dependency in ("after", "requires"):
    assert "postgresql.service" in permissions["provision"][dependency]
    assert "postgresql-setup.service" in permissions["provision"][dependency]
for field, directory, server in (
    ("backendTemplates", "/srv/games/minecraft/survival/plugins/LuckPerms", "survival"),
    ("proxyTemplates", "/srv/games/minecraft/velocity/plugins/luckperms", "velocity"),
):
    template = permissions[field][f"{directory}/config.yml"]
    assert template["replacements"] == {
        "@LUCKPERMS_PASSWORD@": "/run/agenix/games/minecraft/luckperms-db-password"
    }
    configuration = yaml.safe_load(pathlib.Path(template["source"]).read_text())
    assert configuration["server"] == server
    assert configuration["storage-method"] == "postgresql"
    assert configuration["messaging-service"] == "pluginmsg"
    assert not configuration["auto-install-translations"]
    assert configuration["data"]["address"] == "127.0.0.1:5432"
    assert configuration["data"]["database"] == "luckperms"
    assert configuration["data"]["username"] == "luckperms"
    assert configuration["data"]["password"] == "@LUCKPERMS_PASSWORD@"
    bootstrap = json.loads(
        pathlib.Path(
            permissions[field][f"{directory}/bootstrap.json"]["source"]
        ).read_text()
    )
    assert "default" in bootstrap["groups"]
    assert {"key": "group.default", "value": True} in bootstrap["groups"]["mod"][
        "nodes"
    ]
    assert {"key": "group.mod", "value": True} in bootstrap["groups"]["admin"]["nodes"]
    assert {"key": "group.default", "value": True} not in bootstrap["groups"]["admin"][
        "nodes"
    ]
    assert {"key": "*", "value": True} in bootstrap["groups"]["admin"]["nodes"]
    assert bootstrap["tracks"] == {"staff": {"groups": ["default", "mod", "admin"]}}
    default_nodes = {
        node["key"] for node in bootstrap["groups"]["default"]["nodes"] if node["value"]
    }
    assert {
        "skinsrestorer.command.set",
        "voicechat.listen",
        "voicechat.speak",
        "voicechat.groups",
        "huskhomes.max_homes.10",
        "huskhomes.command.home",
        "huskhomes.command.sethome",
        "huskhomes.command.delhome",
        "huskhomes.command.homelist",
        "huskhomes.command.edithome.privacy",
        "huskhomes.command.tpa",
        "huskhomes.command.tpahere",
        "huskhomes.command.tpaccept",
        "huskhomes.command.tpdecline",
        "axgraves.help",
        "axgraves.list",
        "axgraves.allowgraves",
    } <= default_nodes
    assert "*" not in default_nodes and "axgraves.admin" not in default_nodes
    mod_nodes = {
        node["key"] for node in bootstrap["groups"]["mod"]["nodes"] if node["value"]
    }
    assert {
        "minecraft.command.kick",
        "velocity.command.kick",
        "huskhomes.command.tp",
        "minecraft.command.gamemode",
        "axgraves.list.other",
        "axgraves.admin",
    } <= mod_nodes
    assert "*" not in mod_nodes
    assert bootstrap["users"] == {
        "3f771d00-3456-4007-8d66-13fe158488fa": {
            "primaryGroup": "admin",
            "nodes": [{"key": "group.admin", "value": True}],
        }
    }

building = json.loads(pathlib.Path(sys.argv[7]).read_text())
assert building["withoutBackends"] == {}
expected_building = {
    "FastAsyncWorldEdit": "2.16.0",
    "FastAsyncVoxelSniper": "3.2.5",
    "WorldEditSelectionVisualizer": "2.1.10",
}
inventory = {plugin["name"]: plugin for plugin in building["inventory"]}
for name, version in expected_building.items():
    assert inventory[name] == {"name": name, "version": version, "installed": True}
    assert f"/srv/games/minecraft/survival/plugins/{name}" in building["statePaths"]
assert not expected_building.keys() & {
    plugin["name"] for plugin in building["proxyInventory"]
}
for key, name in zip(
    ("fawe", "voxelsniper", "worldedit-visualizer"), expected_building
):
    assert building["symlinks"][f"plugins/{key}.jar"] == building["plugins"][key]
    with zipfile.ZipFile(building["plugins"][key]) as jar:
        metadata = yaml.safe_load(jar.read("plugin.yml"))
        assert metadata["name"] == name
        assert str(metadata["version"]).startswith(expected_building[name])
        if key == "fawe":
            assert "WorldEdit" in metadata["provides"]
        else:
            assert (
                "FastAsyncWorldEdit" if key == "voxelsniper" else "WorldEdit"
            ) in metadata["depend"]
            defaults = yaml.safe_load(jar.read("config.yml"))
            configured = yaml.safe_load(
                pathlib.Path(
                    building["templates"][
                        f"/srv/games/minecraft/survival/plugins/{name}/config.yml"
                    ]["source"]
                ).read_text()
            )
            assert configured.keys() <= defaults.keys()


def building_config(name):
    return yaml.safe_load(
        pathlib.Path(
            building["templates"][
                f"/srv/games/minecraft/survival/plugins/{name}/config.yml"
            ]["source"]
        ).read_text()
    )


fawe = building_config("FastAsyncWorldEdit")
assert not fawe["region-restrictions"]
assert not any(fawe["enabled-components"].values())
for profile in ("default", "builder"):
    limit = fawe["limits"][profile]
    assert limit["max-actions"] == 1
    assert limit["max-changes"] == 100000
    assert limit["max-checks"] == 1000000
    assert limit["max-radius"] == 32
    assert limit["max-brush-radius"] == 8
    assert limit["max-iterations"] == 10
    assert limit["max-entities"] == 0
    assert limit["max-blockstates"] == 1000
    assert limit["max-history-mb"] == 128
    assert limit["inventory-mode"] == 0
    assert limit["confirm-large"]
assert fawe["history"]["use-disk"] and fawe["history"]["store-redo"]
assert fawe["history"]["delete-after-days"] == 7
assert not fawe["history"]["delete-disk-on-logout"]
sniper = building_config("FastAsyncVoxelSniper")
assert sniper["config-version"] == 7
assert not sniper["update-checker"]["enabled"]
assert sniper["litesniper-max-brush-size"] == 8
visualizer = building_config("WorldEditSelectionVisualizer")
assert not visualizer["check-updates"]
assert visualizer["default-enabled"] == {"selection": True, "clipboard": False}
for mode in ("selection", "clipboard"):
    visualization = visualizer["visualization"][mode]
    assert visualization["max-selection-size"] == 100000
    for points in ("primary", "secondary", "origin"):
        assert visualization[points]["view-distance"] == 32
        assert visualization[points]["update-interval"] == 20
        assert visualization[points]["particles"]["type"] == "FLAME"

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    (root / "web").mkdir()
    (root / "web/index.html").write_text("persisted map")
    (root / "web/.token").write_text("private fixture")
    (root / "secret.txt").write_text("outside webroot")
    (root / "web/tiles").mkdir()
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    configuration = root / "nginx.conf"
    configuration.write_text(
        pathlib.Path(sys.argv[2])
        .read_text()
        .replace("@ROOT@", directory)
        .replace("@PORT@", str(port))
    )
    process = subprocess.Popen(
        ["nginx", "-c", str(configuration), "-p", directory, "-g", "daemon off;"]
    )

    def request(path, method="GET"):
        try:
            with urllib.request.urlopen(
                urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method),
                timeout=2,
            ) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()

    try:
        for _ in range(100):
            try:
                if request("/index.html")[0] == 200:
                    break
            except urllib.error.URLError:
                time.sleep(0.02)
        # No game/proxy process is running in this test.
        assert request("/index.html") == (200, b"persisted map")
        assert request("/index.html", "HEAD")[0] == 200
        assert request("/index.html", "POST")[0] == 405
        assert request("/.token")[0] == 403
        assert request("/tiles/")[0] == 403
        status, content = request("/../secret.txt")
        assert 400 <= status < 500 and b"outside webroot" not in content
    finally:
        process.terminate()
        process.wait(timeout=5)

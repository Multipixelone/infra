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
assert discord_defaults["ConfigVersion"] == "1.30.5"
for case in cases:
    assert case["installed"] == case["expected"]
    assert not case["baseAvailable"]  # No mandatory Minecraft credentials in these fixtures.
    assert case["tokenCopy"] is None  # Text-only preparation is outside generic raw-byte copying.
    token_hooks = [entry for entry in case["preStart"] if "minecraft-discord-token-prepare" in entry]
    if case["expected"]:
        assert len(token_hooks) == 1
        assert token_hooks[0].startswith("+")
        assert token_hooks[0].endswith(" /run/agenix/games/minecraft/discordsrv-token /srv/games/minecraft/survival/plugins/DiscordSRV/.token")
        prepare_index = next(i for i, entry in enumerate(case["preStart"]) if "games-prepare" in entry)
        assert prepare_index < case["preStart"].index(token_hooks[0])
        assert case["declaredSecret"] == "0400"
        assert any(path.endswith("plugins/DiscordSRV") for path in case["statePaths"])
        configuration = yaml.safe_load(pathlib.Path(case["configuration"]).read_text())
        messages = yaml.safe_load(pathlib.Path(case["messages"]).read_text())
        assert configuration.keys() <= discord_defaults.keys()
        assert messages.keys() <= message_defaults.keys()
        channels = {"global": case["discord"]["channelId"]}
        if case["discord"]["eventsChannelId"]:
            channels.update(join=case["discord"]["eventsChannelId"], leave=case["discord"]["eventsChannelId"])
        assert configuration["Channels"] == channels
        assert next(iter(configuration["Channels"])) == "global"
        assert configuration["DiscordConsoleChannelId"] == case["discord"]["consoleChannelId"]
        assert configuration["DiscordConsoleChannelBlacklistActsAsWhitelist"] is True
        assert configuration["DiscordConsoleChannelBlacklistedCommands"] == ["list", "tps"]
        assert configuration["DiscordConsoleChannelBlockBots"] is True
        assert not configuration["DiscordChatChannelConsoleCommandEnabled"]
        assert configuration["DiscordConsoleChannelLogRefreshRateInSeconds"] == 5
        assert configuration["DiscordConsoleChannelLevels"] == ["info", "warn", "error"]
        for event in ("Join", "FirstJoin", "Leave", "Death", "Achievement"):
            assert messages[f"MinecraftPlayer{event}Message"]["Enabled"]
            assert "Channel" not in messages[f"MinecraftPlayer{event}Message"]
    else:
        assert token_hooks == []
        assert not any(path.endswith("plugins/DiscordSRV") for path in case["statePaths"])
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
assert "host luckperms luckperms 127.0.0.1/32 scram-sha-256" in permissions["authentication"]
assert "host luckperms luckperms ::1/128 scram-sha-256" in permissions["authentication"]
assert permissions["secret"] == {"owner": "minecraft", "group": "minecraft", "mode": "0400"}
assert permissions["provision"] == {
    "User": "postgres",
    "LoadCredential": ["password:/run/agenix/games/minecraft/luckperms-db-password"],
}
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
    bootstrap = json.loads(pathlib.Path(permissions[field][f"{directory}/bootstrap.json"]["source"]).read_text())
    assert "default" in bootstrap["groups"]
    assert {"key": "group.default", "value": True} in bootstrap["groups"]["mod"]["nodes"]
    assert {"key": "group.mod", "value": True} in bootstrap["groups"]["admin"]["nodes"]
    assert {"key": "group.default", "value": True} not in bootstrap["groups"]["admin"]["nodes"]
    assert {"key": "*", "value": True} in bootstrap["groups"]["admin"]["nodes"]
    assert bootstrap["tracks"] == {"staff": {"groups": ["default", "mod", "admin"]}}
    default_nodes = {node["key"] for node in bootstrap["groups"]["default"]["nodes"] if node["value"]}
    assert {"skinsrestorer.command.set", "voicechat.listen", "voicechat.speak", "voicechat.groups",
            "huskhomes.max_homes.10", "huskhomes.command.home", "huskhomes.command.sethome",
            "huskhomes.command.delhome", "huskhomes.command.homelist", "huskhomes.command.edithome.privacy",
            "huskhomes.command.tpa", "huskhomes.command.tpahere", "huskhomes.command.tpaccept",
            "huskhomes.command.tpdecline", "axgraves.help", "axgraves.list", "axgraves.allowgraves"} <= default_nodes
    assert "*" not in default_nodes and "axgraves.admin" not in default_nodes
    mod_nodes = {node["key"] for node in bootstrap["groups"]["mod"]["nodes"] if node["value"]}
    assert {"minecraft.command.kick", "velocity.command.kick", "huskhomes.command.tp",
            "minecraft.command.gamemode", "axgraves.list.other", "axgraves.admin"} <= mod_nodes
    assert "*" not in mod_nodes
    assert bootstrap["users"] == {
        "3f771d00-3456-4007-8d66-13fe158488fa": {
            "primaryGroup": "admin",
            "nodes": [{"key": "group.admin", "value": True}],
        }
    }

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
    configuration.write_text(pathlib.Path(sys.argv[2]).read_text().replace("@ROOT@", directory).replace("@PORT@", str(port)))
    process = subprocess.Popen(["nginx", "-c", str(configuration), "-p", directory, "-g", "daemon off;"])
    def request(path, method="GET"):
        try:
            with urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method), timeout=2) as response:
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

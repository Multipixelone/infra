"""Check managed inventory access, optional chat, and event ownership together."""

import gzip
import json
import pathlib
import shlex
import subprocess
import sys
import tempfile
import zipfile

import yaml

fixtures = json.loads(pathlib.Path(sys.argv[1]).read_text())
artifacts = json.loads(pathlib.Path(sys.argv[2]).read_text())
sources = pathlib.Path(sys.argv[3])
assert fixtures["noPaper"]["backends"] == {}

with zipfile.ZipFile(artifacts["openinv"]) as jar:
    descriptor = yaml.safe_load(jar.read("plugin.yml"))
    defaults = yaml.safe_load(jar.read("config.yml"))
assert descriptor["version"] == "5.3.5"
assert descriptor["libraries"] == ["org.xerial:sqlite-jdbc:3.49.1.0"]
with zipfile.ZipFile(artifacts["minecraftClient"]) as jar:
    vanilla_language = json.loads(jar.read("assets/minecraft/lang/en_us.json"))


def permission_nodes(bootstrap, group):
    return {
        node["key"] for node in bootstrap["groups"][group]["nodes"] if node["value"]
    }


for name, fixture in fixtures.items():
    if name == "noPaper":
        continue
    chat = name != "missingSecrets"
    assert not {"openinv", "carbon", "miniplaceholders", "flectonepulse"} & set(
        fixture["proxyJars"]
    )
    assert set(fixture["servers"]) == (
        {"survival", "testing"} if name == "additionalBackend" else {"survival"}
    )
    for server_id, server in fixture["servers"].items():
        plugins = fixture["backends"][server_id]
        root = f"/srv/games/minecraft/{server_id}"
        directory = f"{root}/plugins"
        assert not server["available"]  # Polish never bypasses mandatory secrets.
        inventory = {entry["name"]: entry for entry in plugins["inventory"]}
        assert inventory["OpenInv"] == {
            "name": "OpenInv",
            "version": "5.3.5",
            "installed": True,
        }
        assert inventory["CarbonChat"]["installed"] == chat
        assert inventory["MiniPlaceholders"]["installed"] == chat
        assert inventory["MiniPlaceholders LuckPerms Expansion"]["installed"] == chat
        assert inventory["FlectonePulse"]["installed"]
        assert {"openinv", "flectonepulse"} <= plugins["jars"].keys()
        assert ("carbon" in plugins["jars"]) == chat
        assert ("miniplaceholders" in plugins["jars"]) == chat

        def template(path, plugins=plugins):
            return pathlib.Path(plugins["templates"][path]["source"])

        own = yaml.safe_load(template(f"{directory}/OpenInv/config.yml").read_text())
        assert own["config-version"] == defaults["config-version"] == 8
        assert own["settings"]["command"]["open"]["no-args-opens-self"]
        assert not own["settings"]["disable-offline-access"]
        assert not own["settings"]["disable-saving"]
        aliases = yaml.safe_load(template(f"{root}/commands.yml").read_text())[
            "aliases"
        ]
        assert aliases == {
            "invsee": ["openinv:openinv $1-"],
            "endersee": ["openinv:openender $1-"],
            "ec": ["openinv:openender"],
        }
        assert f"{directory}/OpenInv" in server["worldPaths"]
        assert f"{directory}/FlectonePulse" in server["worldPaths"]
        event_config = yaml.safe_load(
            template(f"{directory}/FlectonePulse/config.yml").read_text()
        )
        event_messages = yaml.safe_load(
            template(f"{directory}/FlectonePulse/message.yml").read_text()
        )
        event_commands = yaml.safe_load(
            template(f"{directory}/FlectonePulse/command.yml").read_text()
        )
        integrations = yaml.safe_load(
            template(f"{directory}/FlectonePulse/integration.yml").read_text()
        )
        event_language = yaml.safe_load(
            template(f"{directory}/FlectonePulse/localizations/en_us.yml").read_text()
        )["message"]
        assert event_config["internal"]["vanilla_commands_to_remove"] == []
        assert event_config["database"]["type"] == "H2"
        assert not event_config["database"]["use_playtime_tracking"]
        assert not event_config["metrics"]["enable"]
        assert not event_commands["enable"] and not integrations["enable"]
        assert {
            key
            for key, value in event_messages.items()
            if isinstance(value, dict) and value.get("enable")
        } == {"format", "join", "quit", "vanilla"}
        assert not event_messages["vanilla"]["cancel_default_death_screen"]
        assert (
            event_messages["join"]["range"]
            == event_messages["quit"]["range"]
            == "SERVER"
        )
        assert (
            "joined Survival for the first time"
            in event_language["join"]["format_first_time"]
        )
        assert "left Survival" in event_language["quit"]["format"]
        death_types = event_messages["vanilla"]["types"]
        assert len(death_types) == 1 and death_types[0]["name"] == "DEATH"
        death_formats = event_language["vanilla"]["types"]
        assert set(death_formats) == set(death_types[0]["translation_keys"])
        assert "death.attack.badRespawnPoint.link" not in death_formats
        for key in (
            "death.attack.fall",
            "death.attack.player.item",
            "death.attack.drown",
        ):
            assert key in death_formats
            assert "<argument:0>" in death_formats[key]
        assert "<argument:2>" in death_formats["death.attack.player.item"]
        assert "was slain by" in death_formats["death.attack.player.item"]
        assert (
            "fell" in vanilla_language["death.attack.fall"]
            or "ground" in vanilla_language["death.attack.fall"]
        )
        assert (
            server["symlinks"]["plugins/FlectonePulse/libraries"]
            == artifacts["flectonepulseCache"]
        )
        for path in pathlib.Path(artifacts["openinvCache"]).rglob(
            "_remote.repositories"
        ):
            assert ">central=" in path.read_text()
            relative = path.parent.relative_to(artifacts["openinvCache"])
            assert server["symlinks"][f"libraries/{relative}"] == str(path.parent)

        channel = f"{directory}/CarbonChat/channels/global.conf"
        expansion_path = "plugins/MiniPlaceholders/expansions/LuckPerms-Expansion.jar"
        if not chat:
            assert channel not in plugins["templates"]
            assert expansion_path not in server["symlinks"]
            assert f"{directory}/CarbonChat" not in server["worldPaths"]
            continue
        assert server["symlinks"][expansion_path] == artifacts["luckpermsExpansion"]
        for path in pathlib.Path(artifacts["carbonCache"]).rglob("*.jar"):
            relative = path.relative_to(artifacts["carbonCache"])
            assert server["symlinks"][
                f"plugins/CarbonChat/libraries/{relative}"
            ] == str(path)
        # Individual jar links leave Gremlin's .last-used siblings writable.
        assert "plugins/CarbonChat/libraries" not in server["symlinks"]
        config = template(f"{directory}/CarbonChat/config.conf").read_text()
        global_channel = template(channel).read_text()
        assert 'default-channel="carbon:global"' in config
        assert "messaging-settings { enabled=false }" in config
        assert "discordsrv { enabled=true }" in config
        assert (
            'quick-prefix=""' in global_channel
            and "cross-server=false" in global_channel
        )
        assert "<luckperms_prefix>" in global_channel
        assert "<luckperms_meta:chat_color:s>" in global_channel
        bootstrap_path = f"{directory}/LuckPerms/bootstrap.json.gz"
        compressed = template(bootstrap_path).read_bytes()
        assert compressed[:3] == b"\x1f\x8b\x08"
        assert compressed[3] == 0  # No filename or optional gzip header fields.
        assert compressed[4:8] == b"\0" * 4  # No build timestamp.
        raw = gzip.decompress(compressed)
        assert (
            subprocess.run(
                ["gzip", "-n", "-c"], input=raw, capture_output=True, check=True
            ).stdout
            == compressed
        )
        assert plugins["templates"][bootstrap_path]["mode"] == "0600"
        bootstrap = json.loads(raw)
        assert (not bootstrap["users"]) == (name == "withoutAdmin")
        if bootstrap["users"]:
            assert bootstrap["users"] == {
                "3f771d00-3456-4007-8d66-13fe158488fa": {
                    "primaryGroup": "admin",
                    "nodes": [{"key": "group.admin", "value": True}],
                }
            }
        commands = [
            shlex.split(line)
            for line in template(f"{directory}/LuckPerms/chat-inventory.commands")
            .read_text()
            .splitlines()
        ]
        groups = bootstrap["tracks"]["staff"]["groups"]
        assert commands[: len(groups)] == [
            ["lp", "creategroup", group] for group in groups
        ]
        expected = commands[: len(groups)].copy()
        for group, data in bootstrap["groups"].items():
            for node in data["nodes"]:
                key, value = node["key"], str(node["value"]).lower()
                if key.startswith("group.") and node["value"]:
                    command = ["parent", "add", key.removeprefix("group.")]
                elif key.startswith("weight."):
                    command = ["setweight", key.removeprefix("weight.")]
                elif key.startswith("meta."):
                    meta, content = key.removeprefix("meta.").split(".", 1)
                    command = ["meta", "set", meta, content]
                elif key.startswith("prefix."):
                    priority, prefix = key.removeprefix("prefix.").split(".", 1)
                    command = ["meta", "setprefix", priority, prefix]
                else:
                    command = ["permission", "set", key, value]
                expected.append(["lp", "group", group, *command])
        for uuid, user in bootstrap["users"].items():
            expected.extend(
                [
                    ["lp", "user", uuid, "parent", "add", "admin"],
                    [
                        "lp",
                        "user",
                        uuid,
                        "parent",
                        "switchprimarygroup",
                        user["primaryGroup"],
                    ],
                ]
            )
        # Exact command coverage also excludes imports, clearing, removals and
        # track writes that could discard unrelated interactive state.
        assert sorted(commands) == sorted(expected)
        default = permission_nodes(bootstrap, "default")
        mod = permission_nodes(bootstrap, "mod")
        assert {
            "openinv.enderchest.edit.self",
            "openinv.access.online",
            "carbon.channel.global",
            "carbon.channel.global.see",
            "carbon.channel.global.speak",
        } <= default
        assert {
            "openinv.inventory.open.other",
            "openinv.enderchest.open.other",
            "openinv.access.offline",
            "openinv.access.crossworld",
        } <= mod
        assert not {"openinv.inventory.edit.other", "openinv.enderchest.edit.other"} & (
            default | mod
        )
        assert "*" in permission_nodes(bootstrap, "admin")
        for group, weight in (
            ("default", 0),
            ("builder", 10),
            ("mod", 20),
            ("admin", 30),
        ):
            nodes = permission_nodes(bootstrap, group)
            assert f"weight.{weight}" in nodes
            assert (
                len([node for node in nodes if node.startswith("meta.chat_color.")])
                == 1
            )
            assert len([node for node in nodes if node.startswith("prefix.")]) == (
                group != "default"
            )

# Exercise real parsers and resolvers, rather than treating configuration syntax
# as proof that the plugins will load or render the declared format.
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    embedded = root / "paperlibs"
    embedded.mkdir()
    paper_jar = pathlib.Path(artifacts["paper"]) / "lib/minecraft/server.jar"
    with zipfile.ZipFile(paper_jar) as jar:
        for name in jar.namelist():
            if name.startswith("META-INF/libraries/") and name.endswith(".jar"):
                (embedded / pathlib.Path(name).name).write_bytes(jar.read(name))
    with zipfile.ZipFile(artifacts["flectonepulse"]) as jar:
        inner = root / "flectonepulse-inner.jar"
        inner.write_bytes(jar.read("flectonepulse-bukkit.jarinjar"))
    classes = root / "classes"
    classes.mkdir()
    libraries = [
        str(path)
        for key in ("carbonCache", "flectonepulseCache")
        for path in pathlib.Path(artifacts[key]).rglob("*.jar")
    ]
    classpath = ":".join(
        [
            str(classes),
            str(inner),
            f"{embedded}/*",
            *[
                artifacts[key]
                for key in (
                    "carbon",
                    "miniplaceholders",
                    "luckpermsExpansion",
                    "luckperms",
                    "flectonepulse",
                    "log4jApi",
                    "discordsrv",
                    "geyser",
                )
            ],
            *libraries,
        ]
    )
    helpers = ("ResolveCarbon", "ReadCarbon", "CheckCarbonBridge", "ResolveFlectone")
    subprocess.run(
        [
            "javac",
            "-cp",
            classpath,
            "-d",
            str(classes),
            *[str(sources / f"{name}.java") for name in helpers],
        ],
        check=True,
    )
    subprocess.run(
        [
            "java",
            "-cp",
            classpath,
            "ResolveCarbon",
            artifacts["carbonCache"],
            str(root / "carbon-libraries"),
        ],
        check=True,
    )
    template_dir = "/srv/games/minecraft/survival/plugins"
    templates = fixtures["withLuckPerms"]["backends"]["survival"]["templates"]
    subprocess.run(
        [
            "java",
            "-cp",
            classpath,
            "ReadCarbon",
            *[
                templates[f"{template_dir}/{path}"]["source"]
                for path in (
                    "CarbonChat/config.conf",
                    "CarbonChat/channels/global.conf",
                    "LuckPerms/bootstrap.json.gz",
                )
            ],
            str(pathlib.Path(fixtures["withLuckPerms"]["rankPack"]) / "rank-icons.zip"),
        ],
        check=True,
    )
    # Guard the exact pinned proxy's handling of required Java packs: Bedrock
    # reports success without downloading them, rather than being disconnected.
    handler = subprocess.run(
        [
            "javap",
            "-c",
            "-p",
            "-classpath",
            artifacts["geyser"],
            "org.geysermc.geyser.translator.protocol.java.JavaClientboundResourcePackPushPacket",
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    assert "isRequired:()Z" in handler
    accepted, downloaded, loaded, declined = [
        handler.index(f"ResourcePackStatus.{status}:")
        for status in ("ACCEPTED", "DOWNLOADED", "SUCCESSFULLY_LOADED", "DECLINED")
    ]
    assert accepted < downloaded < loaded < declined
    subprocess.run(["java", "-cp", classpath, "CheckCarbonBridge"], check=True)
    (root / "libraries").symlink_to(
        artifacts["flectonepulseCache"], target_is_directory=True
    )
    subprocess.run(["java", "-cp", classpath, "ResolveFlectone", str(root)], check=True)

print(
    "PASS: optional chat matrix, inventory access grants, aliases, rank precedence, offline cache links"
)

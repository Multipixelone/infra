"""Optional credentials must not disable Minecraft; static maps survive sleep."""

import gzip
import json
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

import yaml

cases = json.loads(pathlib.Path(sys.argv[1]).read_text())
for case in cases:
    assert any(path.endswith("plugins/BlueMap") for path in case["statePaths"])
    assert any(path.endswith("plugins/SkinsRestorer") for path in case["statePaths"])

with zipfile.ZipFile(sys.argv[3]) as jar:
    assert "libraries:" not in jar.read("plugin.yml").decode()
    assert "com/flowpowered/math/vector/Vector3d.class" in jar.namelist()

map_data = json.loads(pathlib.Path(sys.argv[8]).read_text())
map_fixtures = map_data["fixtures"]
assert map_fixtures["noPaper"]["backends"] == {}
with zipfile.ZipFile(map_data["floodgate"]) as jar:
    descriptor = yaml.safe_load(jar.read("plugin.yml"))
    assert descriptor["name"] == "BlueMapFloodgate"
    assert str(descriptor["version"]) == "3.6"
    assert str(descriptor["api-version"]) == "1.17"
    assert descriptor["depend"] == ["BlueMap"]
    assert descriptor["softdepend"] == ["floodgate"]
    assert "libraries" not in descriptor
    assert "bluemap.addon.json" not in jar.namelist()
    assert descriptor["main"].replace(".", "/") + ".class" in jar.namelist()
    for entry in jar.namelist():
        if entry.endswith(".class"):
            minor, major = struct.unpack(">HH", jar.read(entry)[4:8])
            assert minor == 0 and major <= 69, entry
with zipfile.ZipFile(map_data["offline"]) as jar:
    descriptor = yaml.safe_load(jar.read("plugin.yml"))
    assert descriptor["name"] == "BlueMapOfflinePlayerMarkers"
    assert str(descriptor["version"]) == "3.3"
    assert str(descriptor["api-version"]) == "1.13"
    assert descriptor["depend"] == ["BlueMap"]
    assert "libraries" not in descriptor
    assert "bluemap.addon.json" not in jar.namelist()
    assert descriptor["main"].replace(".", "/") + ".class" in jar.namelist()
    for entry in jar.namelist():
        if entry.endswith(".class"):
            minor, major = struct.unpack(">HH", jar.read(entry)[4:8])
            assert minor == 0 and major <= 69, entry
for name, case in map_fixtures.items():
    if name == "noPaper":
        continue
    assert "bluemap-floodgate" not in case["proxyJars"]
    assert "bluemap-offline-markers" not in case["proxyJars"]
    for server_id, server in case["servers"].items():
        plugins = case["backends"][server_id]
        assert plugins["jars"]["bluemap-floodgate"] == map_data["floodgate"]
        assert (
            server["symlinks"]["plugins/bluemap-floodgate.jar"] == map_data["floodgate"]
        )
        assert not any(
            "/packs/" in key and "floodgate" in key for key in server["symlinks"]
        )
        inventory = {entry["name"]: entry for entry in plugins["inventory"]}
        assert inventory["BlueMapFloodgate"] == {
            "name": "BlueMapFloodgate",
            "version": "3.6",
            "installed": True,
        }
        assert (
            f"/srv/games/minecraft/{server_id}/plugins/BlueMapFloodgate"
            in server["worldPaths"]
        )
        assert (
            "-Dtechnicjelle.updatechecker.disabled"
            in server["environment"]["JAVA_TOOL_OPTIONS"]
        )
        assert plugins["jars"]["bluemap-offline-markers"] == map_data["offline"]
        assert (
            server["symlinks"]["plugins/bluemap-offline-markers.jar"]
            == map_data["offline"]
        )
        assert not any(
            "/packs/" in key and "offline" in key for key in server["symlinks"]
        )
        assert inventory["BlueMapOfflinePlayerMarkers"] == {
            "name": "BlueMapOfflinePlayerMarkers",
            "version": "3.3",
            "installed": True,
        }
        assert (
            f"/srv/games/minecraft/{server_id}/plugins/BlueMapOfflinePlayerMarkers"
            in server["worldPaths"]
        )
        offline_config = plugins["templates"][
            f"/srv/games/minecraft/{server_id}/plugins/BlueMapOfflinePlayerMarkers/config.yml"
        ]["source"]

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    embedded = root / "paperlibs"
    embedded.mkdir()
    with zipfile.ZipFile(
        pathlib.Path(map_data["paper"]) / "lib/minecraft/server.jar"
    ) as jar:
        for entry in jar.namelist():
            if entry.startswith("META-INF/libraries/") and entry.endswith(".jar"):
                (embedded / pathlib.Path(entry).name).write_bytes(jar.read(entry))
    classes = root / "classes"
    classes.mkdir()
    classpath = ":".join(
        [
            str(classes),
            sys.argv[3],
            map_data["floodgate"],
            map_data["offline"],
            map_data["gson"],
            map_data["guava"],
            map_data["fastutil"],
            map_data["examinationApi"],
            map_data["examinationString"],
            f"{embedded}/*",
        ]
    )
    sources = pathlib.Path(sys.argv[9])
    subprocess.run(
        [
            "javac",
            "-cp",
            classpath,
            "-d",
            str(classes),
            str(sources / "BlueMapFixture.java"),
            str(sources / "CheckFloodgate.java"),
            str(sources / "CheckOfflineMarkers.java"),
        ],
        check=True,
    )
    subprocess.run(
        [
            "java",
            "-Dtechnicjelle.updatechecker.disabled",
            "-cp",
            classpath,
            "CheckOfflineMarkers",
            offline_config,
        ],
        cwd=root,
        check=True,
    )
    assets_root = root / "offline-fixture/web/assets"
    offline_assets = {
        str(path.relative_to(assets_root)): path.read_bytes()
        for path in assets_root.rglob("*")
        if path.is_file()
    }
    subprocess.run(
        [
            "java",
            "-Dtechnicjelle.updatechecker.disabled",
            "-cp",
            classpath,
            "CheckFloodgate",
        ],
        cwd=root,
        check=True,
    )
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
    assert configuration["primary-group-calculation"] == "parents-by-weight"
    assert configuration["messaging-service"] == "pluginmsg"
    assert not configuration["auto-install-translations"]
    assert configuration["data"]["address"] == "127.0.0.1:5432"
    assert configuration["data"]["database"] == "luckperms"
    assert configuration["data"]["username"] == "luckperms"
    assert configuration["data"]["password"] == "@LUCKPERMS_PASSWORD@"
    template = permissions[field][f"{directory}/bootstrap.json.gz"]
    assert template["mode"] == "0600"
    assert f"{directory}/bootstrap.json" not in permissions[field]
    bootstrap = json.loads(
        gzip.decompress(pathlib.Path(template["source"]).read_bytes())
    )
    assert "default" in bootstrap["groups"]
    assert {"key": "group.default", "value": True} in bootstrap["groups"]["builder"][
        "nodes"
    ]
    assert {"key": "group.builder", "value": True} in bootstrap["groups"]["mod"][
        "nodes"
    ]
    assert {"key": "group.default", "value": True} not in bootstrap["groups"]["mod"][
        "nodes"
    ]
    assert {"key": "group.mod", "value": True} in bootstrap["groups"]["admin"]["nodes"]
    assert {"key": "group.default", "value": True} not in bootstrap["groups"]["admin"][
        "nodes"
    ]
    assert {"key": "*", "value": True} in bootstrap["groups"]["admin"]["nodes"]
    assert bootstrap["tracks"] == {
        "staff": {"groups": ["default", "builder", "mod", "admin"]}
    }
    for rank, weight in zip(("default", "builder", "mod", "admin"), (0, 10, 20, 30)):
        nodes = bootstrap["groups"][rank]["nodes"]
        assert {"key": f"weight.{weight}", "value": True} in nodes
        prefixes = [node["key"] for node in nodes if node["key"].startswith("prefix.")]
        if rank == "default":
            assert prefixes == []
        else:
            assert len(prefixes) == 1
            assert prefixes[0].startswith(f"prefix.{weight}.")
            color = next(
                node["key"].removeprefix("meta.chat_color.<").removesuffix(">")
                for node in nodes
                if node["key"].startswith("meta.chat_color.")
            )
            assert f"<lang_or:infra.rank.{rank}:'[{rank.title()}]'>" in prefixes[0]
            assert f"<hover:show_text:'{rank.title()}'>" in prefixes[0]
            assert prefixes[0].endswith(f"</hover></{color}> ")
            assert "&" not in prefixes[0]
    builder_nodes = {
        node["key"] for node in bootstrap["groups"]["builder"]["nodes"] if node["value"]
    }
    assert {
        "minecraft.command.gamemode",
        "minecraft.command.gamemode.creative",
        "minecraft.command.gamemode.survival",
        "worldedit.wand",
        "worldedit.region.set",
        "worldedit.region.replace",
        "worldedit.clipboard.copy",
        "worldedit.clipboard.paste",
        "worldedit.history.undo",
        "worldedit.history.redo",
        "worldedit.brush.smooth",
        "fawe.limit.builder",
        "fawe.cancel",
        "voxelsniper.sniper",
        "voxelsniper.brush.ball",
        "wesv.use",
        "wesv.toggle",
    } <= builder_nodes
    assert not any("*" in node for node in builder_nodes)
    assert (
        not {
            "worldedit.regen",
            "worldedit.fast",
            "worldedit.reload",
            "worldedit.limit.unrestricted",
            "worldedit.history.undo.other",
            "worldedit.history.redo.other",
            "worldedit.history.rollback",
            "fawe.admin",
            "fawe.reload",
            "fawe.bypass",
            "fawe.limit.unlimited",
            "fawe.permpack.basic",
            "voxelsniper.admin",
            "voxelsniper.ignorelimitations",
            "wesv.reload",
            "wesv.lock",
        }
        & builder_nodes
    )
    assert not any(
        node.startswith(("worldedit.schematic.", "worldedit.scripting."))
        for node in builder_nodes
    )
    assert (
        not {
            "worldedit.brush.command",
            "worldedit.brush.scattercommand",
            "worldedit.clipboard.download",
        }
        & builder_nodes
    )
    brushes = {
        node.removeprefix("voxelsniper.brush.")
        for node in builder_nodes
        if node.startswith("voxelsniper.brush.")
    }
    assert brushes == {
        "snipe",
        "ball",
        "voxel",
        "disc",
        "voxeldisc",
        "cylinder",
        "overlay",
        "underlay",
        "blendball",
        "blenddisc",
        "blendvoxel",
        "blendvoxeldisc",
    }
    for permission in ("wesv.use", "wesv.toggle", "wesv.lock"):
        assert {"key": permission, "value": False} in bootstrap["groups"]["default"][
            "nodes"
        ]
    assert {"key": "wesv.lock", "value": True} in bootstrap["groups"]["admin"]["nodes"]
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
    assert not any(
        node.startswith(("worldedit.", "fawe.", "voxelsniper.")) for node in mod_nodes
    )
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
    for asset, content in offline_assets.items():
        target = root / "web/assets" / asset
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
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
        for asset, content in offline_assets.items():
            assert request(f"/assets/{asset}") == (200, content)
        assert request("/index.html", "HEAD")[0] == 200
        assert request("/index.html", "POST")[0] == 405
        assert request("/.token")[0] == 403
        assert request("/tiles/")[0] == 403
        status, content = request("/../secret.txt")
        assert 400 <= status < 500 and b"outside webroot" not in content
    finally:
        process.terminate()
        process.wait(timeout=5)

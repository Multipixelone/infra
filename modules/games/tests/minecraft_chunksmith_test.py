"""Check the installed artifact, conservative config, real HTTP/token behavior and client API."""

import base64
import hashlib
import json
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

import yaml


def javap(jar, name, *options):
    return subprocess.check_output(
        ["javap", "-classpath", str(jar), *options, name], text=True
    )


fixtures = json.loads(Path(sys.argv[1]).read_text())
plugin = fixtures["plugin"]
assert base64.b64encode(
    hashlib.sha256(Path(plugin).read_bytes()).digest()
).decode() == ("bc3MtDgRuzOZKUwsvuvEDC0WjgbosTRcvyJvlMr5uuo=")
assert fixtures["without"] == {}
with zipfile.ZipFile(plugin) as archive:
    description = yaml.safe_load(archive.read("plugin.yml"))
    assert description["name"] == "Chunksmith"
    assert (
        description["version"] == "4.6.0" and str(description["api-version"]) == "26.1"
    )
    assert description["permissions"]["chunksmith.command"]["default"] == "op"
    assert "chunky" in description["commands"]["cs"]["aliases"]
    assert "BlueMap" in description["softdepend"] and "libraries" not in description
    config_class = archive.read("com/kishku7/chunksmith/platform/BukkitConfig.class")

settings = []
for name in ("production", "additional"):
    fixture = fixtures[name]
    assert 25568 in fixture["tcp"] and 25568 not in fixture["udp"]
    assert not {25566, 25567, 25575} & set(fixture["tcp"])
    for server_id, backend in fixture["backends"].items():
        root = f"/srv/games/minecraft/{server_id}"
        enabled = server_id == "survival"
        configuration = yaml.safe_load(
            Path(
                backend["templates"][f"{root}/plugins/Chunksmith/config.yml"]["source"]
            ).read_text()
        )
        # Unlike config.yml's six defaults, the artifact's BukkitConfig actually
        # implements the extended keys. Reject unsupported/spelled-wrong keys.
        assert all(key.encode() in config_class for key in configuration)
        assert configuration["continue-on-restart"] is False
        assert configuration["force-load-existing-chunks"] is False
        assert configuration["lod-from-explored-chunks"] is False
        assert configuration["lod-enabled"] == str(enabled).lower()
        assert configuration["lod-backchannel-port"] == 25568
        assert configuration["lod-backchannel-host"] == "mc.finnrut.is"
        assert configuration["lod-backchannel-bind-address"] == "0.0.0.0"
        assert 1 <= configuration["dispatch-max-concurrent"] <= 2
        assert configuration["throttle-tick-budget-millis"] == 5
        assert configuration["throttle-max-heap-percent"] <= 75
        assert configuration["throttle-max-queued-writes"] <= 100
        assert configuration["throttle-max-lod-queue"] <= 64
        assert configuration["auto-pause-on-overload"] is True
        assert configuration["auto-pause-grace-seconds"] == 30
        assert configuration["lod-index-budget-mb"] == 256
        assert (
            yaml.safe_load(
                Path(
                    backend["templates"][f"{root}/plugins/bStats/config.yml"]["source"]
                ).read_text()
            )["enabled"]
            is False
        )
        assert not any("/plugins/Chunky/" in path for path in backend["templates"])
        assert (
            backend["jars"]["chunksmith"] == plugin and "chunky" not in backend["jars"]
        )
        symlinks = fixture["symlinks"][server_id]
        assert symlinks["plugins/chunksmith.jar"] == plugin
        assert "plugins/chunky.jar" not in symlinks
        runtime = fixture["runtime"][server_id]
        assert not runtime[
            "wakeOnJoin"
        ]  # Always-on backends keep LOD HTTP running while idle.
        assert {
            f"{root}/plugins/Chunky",
            f"{root}/plugins/Chunksmith",
            f"{root}/world",
        } <= set(runtime["worldPaths"])
        assert runtime["publicTCPPorts"] == ([25568] if enabled else [])
        endpoints = [
            endpoint for endpoint in runtime["public"] if endpoint["edition"] == "LOD"
        ]
        assert endpoints == (
            [
                {
                    "hostname": "mc.finnrut.is",
                    "port": 25568,
                    "protocol": "tcp",
                    "edition": "LOD",
                }
            ]
            if enabled
            else []
        )
        if name == "production":
            settings = [
                key.split("-")[0]
                + "".join(part.title() for part in key.split("-")[1:])
                + "="
                + str(value).lower()
                for key, value in configuration.items()
                if key != "version"
            ]

# Both sides speak the same CSLOD protocol, independently of DH's native protocol.
protocol_class = "com.kishku7.chunksmith.lod.net.CsLodProtocol"
assert javap(plugin, protocol_class, "-constants") == javap(
    sys.argv[4], protocol_class, "-constants"
)
with zipfile.ZipFile(sys.argv[4]) as client:
    metadata = json.loads(client.read("fabric.mod.json"))
    assert metadata["version"] == "4.6.0"
    assert metadata["depends"]["minecraft"] == ">=26.3- <26.4"
    # Check the actual DH overwrite call descriptor against the pinned DH API.
    callers = [
        name[:-6].replace("/", ".")
        for name in client.namelist()
        if name.endswith(".class") and b"overwriteChunkDataAsync" in client.read(name)
    ]
    assert callers
descriptor = (
    "(Lcom/seibel/distanthorizons/api/interfaces/world/IDhApiLevelWrapper;"
    "[Ljava/lang/Object;)Lcom/seibel/distanthorizons/api/objects/DhApiResult;"
)
dh_api = javap(
    sys.argv[5],
    "com.seibel.distanthorizons.api.interfaces.data.IDhApiTerrainDataRepo",
    "-s",
)
assert "overwriteChunkDataAsync" in dh_api and descriptor in dh_api
for caller in callers:
    assert "IDhApiTerrainDataRepo.overwriteChunkDataAsync:" + descriptor in javap(
        sys.argv[4], caller, "-c", "-p"
    )

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    classpath = f"{root}:{plugin}:{sys.argv[3]}:{sys.argv[6]}"
    source = root / "CheckChunksmith.java"
    source.write_text(Path(sys.argv[2]).read_text())
    subprocess.run(
        ["javac", "-cp", classpath, "-d", str(root), str(source)], check=True
    )
    subprocess.run(
        ["java", "-ea", "-cp", classpath, "CheckChunksmith", str(root), *settings],
        check=True,
    )
print(
    "Chunksmith artifact, config, preserved state, TCP endpoint, client protocol and DH API passed"
)

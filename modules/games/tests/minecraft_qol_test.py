"""Validate generated plugin configs and actual loaders without network/server."""
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import zipfile

import yaml

fixtures_file, husk, graves, husk_cache, graves_cache, paper, guava, fastutil, sources, openinv, openinv_cache, bluemap, gson, examination_api, examination_string = sys.argv[1:]
fixtures = json.loads(pathlib.Path(fixtures_file).read_text())
assert fixtures["noPaper"]["backends"] == {}
for name in ("missingSecrets", "additionalBackend"):
    case = fixtures[name]
    assert not {"huskhomes", "axgraves", "simplehome", "simpletpa"} & set(case["proxyJars"])
    assert set(case["servers"]) == ({"survival", "testing"} if name == "additionalBackend" else {"survival"})
    for server_id, server in case["servers"].items():
        assert not server["available"]
        directory = f"/srv/games/minecraft/{server_id}/plugins"
        plugins = case["backends"][server_id]
        assert {"huskhomes", "axgraves"} <= plugins["jars"].keys()
        assert plugins["jars"]["openinv"] == openinv
        assert f"{directory}/OpenInv" in server["worldPaths"]
        own = yaml.safe_load(pathlib.Path(plugins["templates"][f"{directory}/OpenInv/config.yml"]["source"]).read_text())
        assert own["config-version"] == 8
        assert own["settings"]["command"]["open"]["no-args-opens-self"]
        assert not own["settings"]["disable-offline-access"]
        assert not own["settings"]["disable-saving"]
        aliases = yaml.safe_load(pathlib.Path(plugins["templates"][f"/srv/games/minecraft/{server_id}/commands.yml"]["source"]).read_text())["aliases"]
        assert aliases == {"invsee": ["openinv:openinv $1-"], "endersee": ["openinv:openender $1-"], "ec": ["openinv:openender"]}
        assert not {"simplehome", "simpletpa"} & plugins["jars"].keys()
        assert f"{directory}/HuskHomes" in server["worldPaths"]
        assert f"{directory}/AxGraves" in server["worldPaths"]
        assert server["symlinks"]["plugins/AxAPI/libraries/AxGraves"] == graves_cache
        for path in pathlib.Path(husk_cache).rglob("_remote.repositories"):
            relative = path.parent.relative_to(husk_cache)
            assert server["symlinks"][f"libraries/{relative}"] == str(path.parent)
        assert server["symlinks"]["plugins/huskhomes.jar"] == husk
        assert server["symlinks"]["plugins/axgraves.jar"] == graves
        map_config = pathlib.Path(plugins["templates"][f"{directory}/BlueMap/plugin.conf"]["source"]).read_text()
        for key, value in (("write-markers-interval", "30"), ("write-players-interval", "0"), ("live-player-markers", "false")):
            assert re.search(rf'"?{key}"?\s*=\s*{value}\b', map_config)
        home_config = pathlib.Path(plugins["templates"][f"{directory}/HuskHomes/config.yml"]["source"])
        settings = yaml.safe_load(home_config.read_text())
        assert settings["database"]["type"] == "SQLITE"
        assert not settings["cross_server"]["enabled"]
        assert not settings["economy"]["enabled"] and not settings["check_for_updates"]
        assert settings["map_hook"] == {"enabled": True, "show_public_homes": True, "show_warps": True}
        assert settings["general"]["home_delimiter"] == ":"
        offline = yaml.safe_load(pathlib.Path(plugins["templates"][f"{directory}/BlueMapOfflinePlayerMarkers/config.yml"]["source"]).read_text())
        with zipfile.ZipFile(plugins["jars"]["bluemap-offline-markers"]) as jar:
            assert offline.keys() == yaml.safe_load(jar.read("config.yml")).keys()
        assert offline == {"MarkerSetName": "Offline Players", "Toggleable": True, "DefaultHidden": False, "ExpireTimeInHours": 0, "HiddenGameModes": ["spectator"], "HideBannedPlayers": True}
        assert re.search(r'"?skin-download"?\s*=\s*true\b', map_config)
        grave_config = yaml.safe_load(pathlib.Path(plugins["templates"][f"{directory}/AxGraves/config.yml"]["source"]).read_text())
        with zipfile.ZipFile(graves) as jar:
            defaults = yaml.safe_load(jar.read("config.yml"))
            assert grave_config.keys() == defaults.keys()  # Complete pinned schema, no invented options.
            assert grave_config["version"] == defaults["version"] == 19
            descriptor = yaml.safe_load(jar.read("plugin.yml"))
            assert descriptor["version"] == "1.32.1"
            assert {"axgraves.help", "axgraves.list", "axgraves.allowgraves", "axgraves.list.other"} <= descriptor["permissions"].keys()
        assert grave_config["despawn-time-seconds"] == grave_config["grave-limit"] == -1
        assert grave_config["interact-only-own"] and grave_config["instant-pickup-only-own"]
        assert grave_config["xp-keep-percentage"] == 1.0 and grave_config["store-xp"] and grave_config["store-items"]
        assert grave_config["save-graves"] == {"enabled": True, "auto-save-seconds": 30}
        assert grave_config["update-notifier"] == {"enabled": False, "on-join": False}
        assert grave_config["disabled-worlds"] == grave_config["blacklisted-death-causes"] == []
        assert grave_config["blacklisted-items"] == {}

with zipfile.ZipFile(husk) as jar:
    descriptor = yaml.safe_load(jar.read("paper-plugin.yml"))
    assert descriptor["version"] == "4.11-9ed80cc"
    assert descriptor["dependencies"]["server"]["BlueMap"]["join-classpath"]
    assert descriptor["dependencies"]["server"]["BlueMap"]["load"] == "BEFORE"
    assert not descriptor["dependencies"]["server"]["BlueMap"]["required"]
    locales = yaml.safe_load(jar.read("locales/en-gb.yml"))["locales"]
    assert locales["map_hook_public_homes_marker_set_name"] == "Public Homes"
    assert locales["map_hook_warps_marker_set_name"] == "Warps"
    assert "net/william278/huskhomes/hook/BlueMapHook.class" in jar.namelist()
    declarations = yaml.safe_load(jar.read("paper-libraries.yml"))["libraries"]
    assert len(declarations) == 6
    for coordinate in declarations:
        group, artifact, version = coordinate.split(":")
        prefix = pathlib.Path(husk_cache) / group.replace(".", "/") / artifact / version / f"{artifact}-{version}"
        assert prefix.with_suffix(prefix.suffix + ".jar").exists()
        assert prefix.with_suffix(prefix.suffix + ".pom").exists()

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    embedded = root / "paperlibs"
    embedded.mkdir()
    with zipfile.ZipFile(paper) as jar:
        for name in jar.namelist():
            if name.startswith("META-INF/libraries/") and name.endswith(".jar"):
                (embedded / pathlib.Path(name).name).write_bytes(jar.read(name))
    (root / "libraries").symlink_to(husk_cache, target_is_directory=True)
    classes = root / "classes"
    classes.mkdir()
    extra = [str(path) for path in pathlib.Path(husk_cache).rglob("*.jar")]
    classpath = ":".join([str(classes), husk, graves, bluemap, f"{embedded}/*", guava, gson, fastutil, examination_api, examination_string, *extra])
    java_sources = [str(pathlib.Path(sources) / f"{name}.java") for name in ("ResolveHusk", "ResolveAxGraves", "ReadHuskSettings", "ResolveOpenInv", "BlueMapFixture", "CheckHuskMap")]
    subprocess.run(["javac", "-cp", classpath, "-d", str(classes), *java_sources], check=True)
    # Invoke the plugin's real Paper loader/resolver; fail on any transfer.
    subprocess.run(["java", "-cp", classpath, "ResolveHusk", "offline"], cwd=root, check=True)
    # AxAPI's real cache loader must neither download nor invalidate the cache.
    subprocess.run(["java", "-cp", classpath, "ResolveAxGraves", graves_cache], cwd=root, check=True)
    # The upstream parser, not just PyYAML, must recognize our generated keys.
    subprocess.run(["java", "-cp", classpath, "ReadHuskSettings", str(home_config)], cwd=root, check=True)
    subprocess.run(["java", "-cp", classpath, "CheckHuskMap", str(home_config)], cwd=root, check=True)
    # Bukkit's LibraryLoader uses a different repository id from Paper's loader.
    (root / "libraries").unlink()
    (root / "libraries").symlink_to(openinv_cache, target_is_directory=True)
    subprocess.run(["java", "-cp", classpath, "ResolveOpenInv", openinv], cwd=root, check=True)

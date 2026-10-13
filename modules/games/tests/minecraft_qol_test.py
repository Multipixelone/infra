"""Validate generated plugin configs and actual loaders without network/server."""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

import yaml

fixtures_file, husk, graves, husk_cache, graves_cache, paper, guava, fastutil, sources, openinv, openinv_cache, bluemap, gson, examination_api, examination_string = sys.argv[1:]
fixtures = json.loads(pathlib.Path(fixtures_file).read_text())
graves_libraries = pathlib.Path(graves_cache)
graves_metadata = yaml.safe_load((graves_libraries / "cache.yml").read_text())
graves_jars = {path.name for path in graves_libraries.glob("*.jar")}
assert len(graves_jars) == len(graves_metadata["libraries"]) == 9
for library in graves_metadata["libraries"]:
    expected_classifier = None if library["artifact-id"] in {"caffeine", "commons-math3"} else "all" if library["artifact-id"] == "axapi" else ""
    assert library["classifier"] == expected_classifier
assert fixtures["noPaper"]["backends"] == {}
for name in ("missingSecrets", "additionalBackend", "withLuckPerms"):
    case = fixtures[name]
    assert not {"huskhomes", "axgraves", "simplehome", "simpletpa", "tab"} & set(case["proxyJars"])
    assert set(case["servers"]) == ({"survival", "testing"} if name == "additionalBackend" else {"survival"})
    for server_id, server in case["servers"].items():
        assert not server["available"]
        directory = f"/srv/games/minecraft/{server_id}/plugins"
        plugins = case["backends"][server_id]
        # Optional TAB must not install without its LuckPerms credential.
        tab_installed = name == "withLuckPerms"
        assert ("tab" in plugins["jars"]) == tab_installed
        assert next(p for p in plugins["inventory"] if p["name"] == "TAB") == {
            "name": "TAB", "version": "6.2.0", "installed": tab_installed,
        }
        assert (f"{directory}/TAB" in server["worldPaths"]) == tab_installed
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
        cache_relative = "plugins/AxAPI/libraries/AxGraves"
        assert cache_relative not in server["symlinks"]
        assert f"{cache_relative}/cache.yml" not in server["symlinks"]
        cache_links = {path: source for path, source in server["symlinks"].items() if path.startswith(f"{cache_relative}/")}
        assert cache_links == {f"{cache_relative}/{name}": str(graves_libraries / name) for name in graves_jars}
        metadata_template = plugins["templates"][f"/srv/games/minecraft/{server_id}/{cache_relative}/cache.yml"]
        assert metadata_template.get("mode", "0600") == "0600"
        assert pathlib.Path(metadata_template["source"]).read_bytes() == (graves_libraries / "cache.yml").read_bytes()
        for path in pathlib.Path(husk_cache).rglob("_remote.repositories"):
            relative = path.parent.relative_to(husk_cache)
            assert server["symlinks"][f"libraries/{relative}"] == str(path.parent)
        assert server["symlinks"]["plugins/huskhomes.jar"] == husk
        assert server["symlinks"]["plugins/axgraves.jar"] == graves
        map_config = pathlib.Path(plugins["templates"][f"{directory}/BlueMap/plugin.conf"]["source"]).read_text()
        for key, value in (("write-markers-interval", "30"), ("write-players-interval", "3"), ("live-player-markers", "false")):
            assert re.search(rf'"?{key}"?\s*=\s*{value}\b', map_config)
        home_config = pathlib.Path(plugins["templates"][f"{directory}/HuskHomes/config.yml"]["source"])
        settings = yaml.safe_load(home_config.read_text())
        assert settings["database"]["type"] == "SQLITE"
        assert not settings["cross_server"]["enabled"]
        assert not settings["economy"]["enabled"] and not settings["check_for_updates"]
        assert settings["map_hook"] == {"enabled": True, "show_public_homes": True, "show_warps": True}
        assert settings["general"]["home_delimiter"] == ":"
        assert settings["general"]["back_command"] == {"return_by_death": False}
        home_messages = yaml.safe_load(pathlib.Path(plugins["templates"][f"{directory}/HuskHomes/messages-en-gb.yml"]["source"]).read_text())
        with zipfile.ZipFile(husk) as jar:
            upstream_messages = yaml.safe_load(jar.read("locales/en-gb.yml"))
        assert home_messages["locales"]["return_by_death_notification"] == ""
        assert home_messages["locales"]["back_command_description"] == "Return to your previous position"
        # All other messages, including normal travel and map labels, survive.
        for key in ("return_by_death_notification", "back_command_description"):
            upstream_messages["locales"][key] = home_messages["locales"][key]
        assert home_messages == upstream_messages
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
            assert {"axgraves.tp", "axgraves.tp.bypass"} <= descriptor["permissions"].keys()
            upstream_messages = yaml.safe_load(jar.read("messages.yml"))
        grave_messages = yaml.safe_load(pathlib.Path(plugins["templates"][f"{directory}/AxGraves/messages.yml"]["source"]).read_text())
        assert not any("teleport" in line.lower() or "/axgraves tp" in line for line in grave_messages["help"])
        assert "[TP]" not in grave_messages["grave-list"]["grave"]
        assert all(token in grave_messages["grave-list"]["grave"] for token in ("%world%", "%x%", "%y%", "%z%"))
        assert not grave_messages["death-message"]["enabled"]
        for key in ("help", "grave-list"):
            upstream_messages[key] = grave_messages[key]
        assert grave_messages == upstream_messages
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
    def graves_fixture(name):
        cache = root / name / "plugins" / "AxAPI" / "libraries" / "AxGraves"
        cache.mkdir(parents=True)
        # Reproduce declarative jar links and games-prepare's writable copy.
        for filename in graves_jars:
            (cache / filename).symlink_to(graves_libraries / filename)
        shutil.copyfile(graves_libraries / "cache.yml", cache / "cache.yml")
        (cache / "cache.yml").chmod(0o600)
        return cache

    def resolve_graves(cache, expected_failure=None):
        result = subprocess.run(["java", "-cp", classpath, "ResolveAxGraves", str(cache)], cwd=root, text=True, capture_output=True)
        output = result.stdout + result.stderr
        if expected_failure:
            assert result.returncode != 0 and expected_failure in output, output
        else:
            assert result.returncode == 0, output
            assert "An unexpected error" not in output and "ERROR" not in output, output
            print(result.stdout, end="")

    # Fresh JVMs must resolve real production identities and attach the jars,
    # including after AxAPI atomically rewrites metadata on the first load.
    cache = graves_fixture("axgraves-runtime")
    for _ in range(2):
        resolve_graves(cache)
        assert yaml.safe_load((cache / "cache.yml").read_text()) == graves_metadata
        assert all((cache / filename).is_symlink() for filename in graves_jars)
        assert not (cache / "cache.yml").is_symlink()
        assert {path.name for path in cache.iterdir()} == graves_jars | {"cache.yml"}

    # The previous fixture hid null/empty classifier mismatches. Both direct
    # libraries must fail offline if their identities regress independently.
    for artifact in ("commons-math3", "caffeine"):
        broken = graves_fixture(f"axgraves-empty-{artifact}")
        metadata = yaml.safe_load((broken / "cache.yml").read_text())
        for library in metadata["libraries"]:
            if library["artifact-id"] == artifact:
                library["classifier"] = ""
        (broken / "cache.yml").write_text(yaml.safe_dump(metadata))
        resolve_graves(broken, "NETWORK ATTEMPT:")

    caffeine_filename = "com.github.ben-manes.caffeine.caffeine-3.2.3.jar"
    broken = graves_fixture("axgraves-missing-jar")
    (broken / caffeine_filename).unlink()
    resolve_graves(broken, "NETWORK ATTEMPT:")

    broken = graves_fixture("axgraves-missing-class")
    (broken / caffeine_filename).unlink()
    # Point to a separate jar missing precisely the class from the live error.
    damaged = root / "damaged-caffeine.jar"
    with zipfile.ZipFile(graves_libraries / caffeine_filename) as original, zipfile.ZipFile(damaged, "w") as replacement:
        for entry in original.infolist():
            if entry.filename != "com/artillexstudios/axgraves/libs/axapi/libs/caffeine/caffeine/cache/Caffeine.class":
                replacement.writestr(entry, original.read(entry))
    (broken / caffeine_filename).symlink_to(damaged)
    resolve_graves(broken, "ClassNotFoundException: com.artillexstudios.axgraves.libs.axapi.libs.caffeine.caffeine.cache.Caffeine")

    broken = root / "axgraves-immutable-parent"
    broken.symlink_to(graves_libraries, target_is_directory=True)
    resolve_graves(broken, "Metadata must be a writable runtime copy")
    # The upstream parser, not just PyYAML, must recognize our generated keys.
    subprocess.run(["java", "-cp", classpath, "ReadHuskSettings", str(home_config)], cwd=root, check=True)
    subprocess.run(["java", "-cp", classpath, "CheckHuskMap", str(home_config)], cwd=root, check=True)
    # Bukkit's LibraryLoader uses a different repository id from Paper's loader.
    (root / "libraries").unlink()
    (root / "libraries").symlink_to(openinv_cache, target_is_directory=True)
    subprocess.run(["java", "-cp", classpath, "ResolveOpenInv", openinv], cwd=root, check=True)

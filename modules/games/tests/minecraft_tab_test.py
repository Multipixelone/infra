"""Check TAB's pinned schema, optional installation and shared presentation."""

import gzip
import hashlib
import json
import struct
import zipfile
from pathlib import Path

import yaml


def check_tab(fixtures, artifacts):
    jar_path = Path(artifacts["tab"])
    assert (
        hashlib.sha256(jar_path.read_bytes()).hexdigest()
        == "f94331947134242efa478b9b9bf04b29e37861721dee58c32b7ea57779aa735e"
    )
    with zipfile.ZipFile(jar_path) as jar:
        descriptor = yaml.safe_load(jar.read("plugin.yml"))
        defaults = yaml.safe_load(jar.read("config/config.yml"))
        assert descriptor["name"] == "TAB" and descriptor["version"] == "6.2.0"
        assert str(descriptor["api-version"]) == "1.13"
        assert "LuckPerms" in descriptor["softdepend"]
        assert "libraries" not in descriptor
        assert (
            "me/neznamy/tab/platforms/bukkit/paper_26_2/NMSImplementationProvider.class"
            in jar.namelist()
        )
        assert b"26.3" in jar.read("me/neznamy/tab/platforms/bukkit/BukkitTAB.class")
        for name in jar.namelist():
            if name.endswith(".class"):
                minor, major = struct.unpack(">HH", jar.read(name)[4:8])
                assert minor == 0 and major <= 69, name

    for name, fixture in fixtures.items():
        assert "tab" not in fixture["proxyJars"]
        for server_id, server in fixture["servers"].items():
            plugins = fixture["backends"][server_id]
            directory = f"/srv/games/minecraft/{server_id}/plugins"
            ready = "luckperms" in plugins["jars"]
            entry = next(p for p in plugins["inventory"] if p["name"] == "TAB")
            assert entry == {"name": "TAB", "version": "6.2.0", "installed": ready}
            assert ("tab" in plugins["jars"]) == ready
            assert (f"{directory}/TAB" in server["worldPaths"]) == ready
            assert server["discordInviteUrl"] == (server["inviteUrl"] or None)
            if not ready:
                assert not any("/TAB/" in path for path in plugins["templates"])
                continue
            assert plugins["jars"]["tab"] == str(jar_path)
            assert server["symlinks"]["plugins/tab.jar"] == str(jar_path)

            def read(path, plugins=plugins, directory=directory):
                return yaml.safe_load(
                    Path(
                        plugins["templates"][f"{directory}/{path}"]["source"]
                    ).read_text()
                )

            config = read("TAB/config.yml")
            assert config.keys() <= defaults.keys()
            for feature, value in config.items():
                if isinstance(value, dict) and feature not in {
                    "placeholder-refresh-intervals"
                }:
                    assert value.keys() <= defaults[feature].keys(), feature
            assert config["config-version"] == defaults["config-version"] == 7
            enabled = {
                key
                for key, value in config.items()
                if isinstance(value, dict) and value.get("enabled")
            }
            assert enabled == {
                "header-footer",
                "tablist-name-formatting",
                "scoreboard-teams",
            }
            teams = config["scoreboard-teams"]
            assert teams["sorting-types"] == [
                "PLACEHOLDER_HIGH_TO_LOW:%luckperms-weight%",
                "PLACEHOLDER_A_TO_Z:%player%",
            ]
            assert teams["enable-collision"] and not teams["invisible-nametags"]
            assert (
                not teams["can-see-friendly-invisibles"]
                and not teams["case-sensitive-sorting"]
            )
            assert not teams["disable-condition"]
            assert not config["assign-groups-by-permissions"] and not config["debug"]
            assert config["components"]["minimessage-support"]
            assert not config["placeholders"]["register-tab-expansion"]
            assert read("TAB/users.yml") == read("TAB/animations.yml") == {}
            assert not read("bStats/config.yml")["enabled"]
            assert not read("FlectonePulse/message.yml")["scoreboard"]["enable"]
            intervals = config["placeholder-refresh-intervals"]
            assert intervals["%online%"] == intervals["%ping%"] == 1000
            assert intervals["%tps%"] == intervals["%mspt%"] == 5000
            design = config["header-footer"]["designs"]
            assert set(design) == {"default"}
            header, footer = design["default"]["header"], design["default"]["footer"]
            assert header[0] == header[-1] == footer[0] == footer[-1] == ""
            assert (
                "<gradient:#cba6f7:#f5c2e7:#fab387><bold>Finn's Survival</bold></gradient>"
                in header
            )
            assert "mc.finnrut.is" in "\n".join(header)
            assert f"%online%/{server['maxPlayers']}" in "\n".join(header)
            assert "%ping% ms" in "\n".join(header)
            assert "%tps%" in footer[1] and "%mspt%" in footer[1]
            assert server["mapUrl"] in "\n".join(footer)
            assert ("Discord:" in "\n".join(footer)) == bool(server["inviteUrl"])
            if server["inviteUrl"]:
                assert server["inviteUrl"].removeprefix("https://") in "\n".join(footer)
            groups = read("TAB/groups.yml")
            assert groups["_DEFAULT_"]["tabprefix"] == "%luckperms-prefix%"
            assert (
                groups["_DEFAULT_"]["tagprefix"]
                == groups["_DEFAULT_"]["tagsuffix"]
                == ""
            )
            assert groups["_DEFAULT_"]["tabsuffix"] == ""
            bootstrap = json.loads(
                gzip.decompress(
                    Path(
                        plugins["templates"][
                            f"{directory}/LuckPerms/bootstrap.json.gz"
                        ]["source"]
                    ).read_bytes()
                )
            )
            ranks = fixture["ranks"]
            assert set(groups) == set(ranks) | {"_DEFAULT_"}
            assert set(bootstrap["groups"]) == set(ranks)
            for rank, group in bootstrap["groups"].items():
                nodes = {n["key"] for n in group["nodes"] if n["value"]}
                color = next(
                    n["key"].removeprefix("meta.chat_color.")
                    for n in group["nodes"]
                    if n["key"].startswith("meta.chat_color.")
                )
                assert color == f"<{ranks[rank]['color']}>"
                assert f"weight.{ranks[rank]['weight']}" in nodes
                prefixes = {key for key in nodes if key.startswith("prefix.")}
                assert prefixes == (
                    {f"prefix.{ranks[rank]['weight']}.{ranks[rank]['prefix']}"}
                    if "prefix" in ranks[rank]
                    else set()
                )
                assert groups[rank] == {"customtabname": color + "%player%<reset>"}
            assert (
                read("LuckPerms/config.yml")["primary-group-calculation"]
                == "parents-by-weight"
            )
    print(
        "PASS: pinned TAB schema, optional backend inventory, rank source, disabled features and invite/capacity variants"
    )

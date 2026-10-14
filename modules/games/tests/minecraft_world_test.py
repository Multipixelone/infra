"""The snapshot guard precedes pack writes; declarations match the pinned artifacts."""

import hashlib
import json
from pathlib import Path
import sys
import zipfile

import yaml


fixture = json.loads(Path(sys.argv[1]).read_text())
assert fixture["fingerprint"] != fixture["modifiedFingerprint"]
assert "/srv/games/minecraft/survival/world" in fixture["worldPaths"]
assert "/srv/games/minecraft/survival/plugins/Chunky" in fixture["worldPaths"]
assert "/srv/games/minecraft/survival/plugins/bStats" in fixture["worldPaths"]
bstats = fixture["chunky"]["templates"]["/srv/games/minecraft/survival/plugins/bStats/config.yml"]
assert yaml.safe_load(Path(bstats["source"]).read_text())["enabled"] is False
assert "spawn-protection=0\n" in Path(fixture["properties"]).read_text()
assert fixture["user"] == "minecraft"
hooks = fixture["preStart"]
index = lambda name: next(i for i, value in enumerate(hooks) if name in value)
assert index("games-prechange") < index("survival-start-pre") < index("games-prepare") < index("minecraft-datapacks-prepare")
assert not hooks[index("minecraft-datapacks-prepare")].startswith("+")
survival = next(s for s in fixture["manifest"]["servers"] if s["id"] == "survival")
assert survival["datapacks"] == fixture["packs"]["inventory"]
assert not any(pack["name"] == "Anti Enderman Grief" for pack in survival["datapacks"])
assert len(survival["datapacks"]) == 9
assert all(pack["installed"] for pack in survival["datapacks"])
assert set(fixture["packs"]["packs"]) == {
    "confetti-creepers", "player-head-drops", "mini-blocks", "more-mob-heads",
    "custom-nether-portals", "double-shulker-shells", "afk-display", "world-policy", "grave-compass",
}
sources = fixture["sources"]
assert set(fixture["metadataFiles"]) == {"sources.json", "credits.txt", "grave-compass"}
assert sources["minecraftVersion"] == fixture["serverVersion"] == "26.3" and sources["dataPackFormat"] == [121, 0]
assert sources["upstream"] == "https://vanillatweaks.net/picker/datapacks/"
assert sources["bundle"]["id"] == "d326112"
assert sources["bundle"]["retrieved"] == "2026-10-09"
assert sources["bundle"]["sha256"] == "05f9f2a4256b4bf3a40e10b1a250959e6850e9ecf6ff55e68f6aebe0a0f53ce4"
assert "mirror" not in sources and len(sources["packs"]) == 7
assert {"name": "Grave Compass", "version": "26.3 / 1", "installed": True} in survival["datapacks"]
for pack in sources["packs"]:
    assert "mirrorEntry" not in pack
    assert pack["bundleEntry"].endswith(f"v{pack['version']} (MC 26.3).zip")
    source = fixture["packs"]["packs"][pack["id"]]
    assert Path(source).name.endswith("-" + pack["archive"])
    assert hashlib.sha256(Path(source).read_bytes()).hexdigest() == pack["sha256"]
    assert source in fixture["retainedInputs"]
    assert {"name": pack["name"], "version": pack["version"], "installed": True} in survival["datapacks"]
for source in fixture["packs"]["packs"].values():
    with zipfile.ZipFile(source) as archive:
        metadata = json.loads(archive.read("pack.mcmeta"))["pack"]
        assert metadata["min_format"] == metadata["max_format"] == [121, 0]
        assert not any(name.startswith("assets/") for name in archive.namelist())
assert any(p["name"] == "Chunky" and p["version"] == "1.5.3" and p["installed"] for p in survival["plugins"])
assert not any(p["name"] == "ChunkyBorder" for p in survival["plugins"])
with zipfile.ZipFile(sys.argv[2]) as archive:
    defaults = yaml.safe_load(archive.read("config.yml"))
    description = yaml.safe_load(archive.read("plugin.yml"))
    assert description["version"] == "1.5.3"
    assert "libraries" not in description
    assert b"config.yml" in archive.read("org/popcraft/chunky/lib/bstats/bukkit/Metrics.class")
    assert not any("Updater" in name or "UpdateChecker" in name for name in archive.namelist())
configuration = yaml.safe_load(Path(fixture["chunky"]["templates"]["/srv/games/minecraft/survival/plugins/Chunky/config.yml"]["source"]).read_text())
assert configuration.keys() <= defaults.keys()
assert configuration["continue-on-restart"] is False
assert configuration["force-load-existing-chunks"] is False
with zipfile.ZipFile(fixture["packs"]["packs"]["world-policy"]) as archive:
    metadata = json.loads(archive.read("pack.mcmeta"))["pack"]
    assert metadata["min_format"] == metadata["max_format"] == [121, 0]
    assert json.loads(archive.read("data/minecraft/tags/function/load.json"))["values"] == ["infra:world_policy"]
    assert archive.read("data/infra/function/world_policy.mcfunction") == b"gamerule minecraft:players_sleeping_percentage 50\n"

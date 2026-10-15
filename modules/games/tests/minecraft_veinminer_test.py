"""Check the pinned jar, generated policy and real offline parser/resolver."""

import gzip
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import zipfile

import yaml

fixtures_file, plugin, cache, paper, geyser, guava, gson, slf4j, sources = sys.argv[1:]
fixtures = json.loads(pathlib.Path(fixtures_file).read_text())
cache = pathlib.Path(cache)
sources = pathlib.Path(sources)
ores = {
    f"minecraft:{prefix}{ore}_ore"
    for ore in (
        "coal",
        "copper",
        "iron",
        "gold",
        "redstone",
        "lapis",
        "diamond",
        "emerald",
    )
    for prefix in ("", "deepslate_")
} | {
    "minecraft:nether_gold_ore",
    "minecraft:nether_quartz_ore",
    "minecraft:ancient_debris",
}
stone = {"minecraft:diorite", "minecraft:andesite"}
admin_nodes = {
    f"veinminer.{suffix}"
    for suffix in ("toggle", "blocks", "groups", "settings", "reload")
}

assert pathlib.Path(plugin).name.endswith("-veinminer-paper-2.12.3.jar")
assert (
    hashlib.sha256(pathlib.Path(plugin).read_bytes()).hexdigest()
    == "aec0911a8b201b9f4746bbffdde8b336149c265c46d52f6498f2cfc1f48ce1aa"
)
with zipfile.ZipFile(plugin) as jar:
    metadata = yaml.safe_load(jar.read("paper-plugin.yml"))
    assert metadata["name"] == "Veinminer" and metadata["version"] == "2.12.3"
    assert metadata["main"] == "de.miraculixx.veinminer.Veinminer"
    assert metadata["loader"] == "de.miraculixx.veinminer.VeinminerLoader"
    assert metadata["api-version"] == "1.21" and metadata["folia-supported"]
    libraries = json.loads(jar.read("paper-libraries.json"))
    assert libraries["dependencies"] == [
        "org.jetbrains.kotlin:kotlin-stdlib:2.4.20",
        "org.jetbrains.kotlin:kotlin-reflect:2.4.20",
        "org.jetbrains.kotlinx:kotlinx-serialization-json:1.12.0-RC",
        "org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0",
        "org.jetbrains.kotlinx:kotlinx-serialization-cbor:1.12.0-RC",
        "de.miraculixx:kpaper:1.2.1",
    ]
    assert not any("bstats" in name.lower() for name in jar.namelist())

assert fixtures["noPaper"]["backends"] == {}
for case_name, case in fixtures.items():
    assert "veinminer" not in case["proxyJars"]
    if case_name == "noPaper":
        continue
    assert set(case["backends"]) == (
        {"survival", "testing"} if case_name == "additionalBackend" else {"survival"}
    )
    for server_id, backend in case["backends"].items():
        # Adding a plugin must not bypass the existing credential gates.
        assert not backend["available"]
        assert backend["jars"] == {"veinminer": plugin}
        assert backend["inventory"] == [
            {"name": "Veinminer", "version": "2.12.3", "installed": True}
        ]
        directory = f"/srv/games/minecraft/{server_id}/plugins/Veinminer"
        assert directory in backend["worldPaths"]
        assert backend["symlinks"]["plugins/veinminer.jar"] == plugin
        assert set(backend["templates"]) == {
            f"{directory}/{name}.json" for name in ("settings", "groups", "blocks")
        }

        configurations = {
            name: json.loads(
                pathlib.Path(
                    backend["templates"][f"{directory}/{name}.json"]["source"]
                ).read_text()
            )
            for name in ("settings", "groups", "blocks")
        }

        settings = configurations["settings"]
        assert (
            settings["mustSneak"]
            and settings["needCorrectTool"]
            and settings["decreaseDurability"]
        )
        assert settings["maxChain"] == 64 and settings["searchRadius"] == 1
        assert settings["cooldown"] == 20 and settings["delay"] == 0
        assert settings["separateGroupMining"] and settings["permissionRestricted"]
        assert settings["client"] == {
            "allow": True,
            "require": False,
            "allBlocks": True,
            "overrides": {},
        }
        assert (
            not settings["mergeItemDrops"]
            and settings["hungerPerBlock"] == 0.1
            and settings["miningSpeedModifier"] == 0
        )
        assert (
            not settings["autoUpdate"]
            and settings[
                "dontDisplayUpdatesAndIWillNotAskForSupportBeforeUpdatingISwear"
            ]
        )
        assert configurations["blocks"] == []
        groups = configurations["groups"]
        assert [group["name"] for group in groups] == ["Ores", "Decorative stone"]
        assert set(groups[0]["blocks"]) == ores and set(groups[1]["blocks"]) == stone
        for group in groups:
            assert group["tools"] == ["#minecraft:pickaxes"] and not group.get(
                "override"
            )
        assert yaml.safe_load(pathlib.Path(backend["bstats"]).read_text()) == {
            "enabled": False
        }
        for identity in cache.rglob("_remote.repositories"):
            relative = identity.parent.relative_to(cache)
            assert backend["symlinks"][f"libraries/{relative}"] == str(identity.parent)

permissions = fixtures["withLuckPerms"]
bootstrap = json.loads(
    gzip.decompress(pathlib.Path(permissions["permissions"]).read_bytes())
)
nodes = {node["key"]: node["value"] for node in bootstrap["groups"]["default"]["nodes"]}
assert nodes["veinminer.use"] and all(nodes[node] is False for node in admin_nodes)
assert any(
    n == {"key": "group.default", "value": True}
    for n in bootstrap["groups"]["builder"]["nodes"]
)
assert any(
    n == {"key": "group.builder", "value": True}
    for n in bootstrap["groups"]["mod"]["nodes"]
)
assert any(
    n == {"key": "group.mod", "value": True}
    for n in bootstrap["groups"]["admin"]["nodes"]
)
commands = pathlib.Path(permissions["permissionCommands"]).read_text()
assert "lp group default permission set veinminer.use true\n" in commands
assert all(
    f"lp group default permission set {node} false\n" in commands
    for node in admin_nodes
)


def disassemble(jar, name):
    return subprocess.run(
        ["javap", "-p", "-c", "-classpath", str(jar), name],
        check=True,
        text=True,
        capture_output=True,
    ).stdout


def method(code, name):
    match = re.search(
        r"^  (?:public|private).*?\b"
        + name
        + r"\([^\n]*\).*?\n    Code:\n(.*?)(?=\n  (?:public|private|static)|\Z)",
        code,
        re.MULTILINE | re.DOTALL,
    )
    assert match, name
    return match[1]


# Inspect the published event path, including the queued execution-time guards.
# This is bytecode evidence, not a substitute for a live gameplay smoke test.
event = disassemble(plugin, "de.miraculixx.veinminer.VeinMinerEvent")
allowed = method(event, "allowedToVeinmine")
for token in (
    "GameMode.CREATIVE",
    "getMustSneak",
    "Player.isSneaking",
    "getNeedCorrectTool",
    "Block.getDrops",
    "getTools",
    "Set.contains",
    "remainingDurability",
    "getRequire",
):
    assert token in allowed, token
assert re.search(
    r"Player.isSneaking.*?ifne\s+\d+\s+\d+: aconst_null\s+\d+: areturn",
    allowed,
    re.DOTALL,
)
assert re.search(
    r"Block.getDrops:.*?Collection.isEmpty:.*?ifeq\s+\d+\s+\d+: aconst_null\s+\d+: areturn",
    allowed,
    re.DOTALL,
)
breaking = method(event, "triggerBreaking")
assert re.search(
    r"remainingDurability:.*?iconst_1\s+\d+: if_icmpgt\s+\d+\s+\d+: return",
    breaking,
    re.DOTALL,
)
assert re.search(
    r"VeinminerEvent.callEvent:\(\)Z\s+\d+: ifne\s+\d+\s+\d+: return", breaking
)
assert (
    breaking.index("VeinminerEvent.callEvent")
    < breaking.index("Block.getDrops")
    < breaking.index("Method destroy:")
    < breaking.index("Method damageItem:")
)
assert (
    "Block.getDrops:(Lorg/bukkit/inventory/ItemStack;Lorg/bukkit/entity/Entity;)"
    in breaking
)
assert "getXP:" in breaking and "isDropItems" in breaking
assert "ItemStack.damage:(ILorg/bukkit/entity/LivingEntity;)" in method(
    event, "damageItem"
)
assert "EventPriority.MONITOR" in event
assert "extends org.bukkit.event.block.BlockBreakEvent" in disassemble(
    plugin, "de.miraculixx.veinminer.VeinMinerEvent$VeinminerEvent"
)
callbacks = disassemble(
    plugin, "de.miraculixx.veinminer.networking.PaperServerCallbacks"
)
assert "getAllow" in method(callbacks, "onJoinAccepted")
update = disassemble(plugin, "de.miraculixx.veinminer.UpdateManager")
assert (
    "Method update:" in method(update, "checkForUpdates")
    and "getAutoUpdate" not in update
)
geyser_input = disassemble(geyser, "org.geysermc.geyser.session.cache.InputCache")
for token in (
    "isSneaking",
    "withShift",
    "startSneaking",
    "stopSneaking",
    "sendDownstreamGamePacket",
):
    assert token in geyser_input, token

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    embedded = root / "paperlibs"
    embedded.mkdir()
    with zipfile.ZipFile(paper) as jar:
        for name in jar.namelist():
            if name.startswith("META-INF/libraries/") and name.endswith(".jar"):
                (embedded / pathlib.Path(name).name).write_bytes(jar.read(name))
    (root / "libraries").symlink_to(cache, target_is_directory=True)
    classes = root / "classes"
    classes.mkdir()
    base_classpath = ":".join(
        [str(classes), plugin, f"{embedded}/*", guava, gson, slf4j]
    )
    subprocess.run(
        [
            "javac",
            "-cp",
            base_classpath,
            "-d",
            str(classes),
            str(sources / "ResolveVeinminer.java"),
        ],
        check=True,
    )
    result = subprocess.run(
        ["java", "-cp", base_classpath, "ResolveVeinminer"],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    print(result.stdout, end="")
    resolved = [
        line.removeprefix("LIBRARY ")
        for line in result.stdout.splitlines()
        if line.startswith("LIBRARY ")
    ]
    assert len(resolved) == len(set(resolved)) == 14
    filenames = {pathlib.Path(path).name for path in resolved}
    assert filenames == {path.name for path in cache.rglob("*.jar")}
    assert {
        "kotlin-stdlib-2.4.20.jar",
        "kotlin-reflect-2.4.20.jar",
        "kotlinx-serialization-json-jvm-1.12.0-RC.jar",
        "kotlinx-serialization-core-jvm-1.12.0-RC.jar",
        "kotlinx-coroutines-core-jvm-1.11.0.jar",
        "kpaper-1.2.1.jar",
    } <= filenames
    # Only the release loader's selected libraries enter the parser classpath.
    classpath = ":".join([base_classpath, *resolved])
    identifier = root / "Identifier.java"
    identifier.write_text(
        "package net.minecraft.resources; public record Identifier(String value) {}\n"
    )
    subprocess.run(
        [
            "javac",
            "-cp",
            classpath,
            "-d",
            str(classes),
            str(identifier),
            str(sources / "ReadVeinminer.java"),
        ],
        check=True,
    )
    templates = fixtures["withLuckPerms"]["backends"]["survival"]["templates"]
    prefix = "/srv/games/minecraft/survival/plugins/Veinminer"
    subprocess.run(
        [
            "java",
            "-cp",
            classpath,
            "ReadVeinminer",
            *[
                templates[f"{prefix}/{name}.json"]["source"]
                for name in ("settings", "groups")
            ],
        ],
        check=True,
    )

print(
    "PASS: Veinminer artifact, policy, permissions, event guards and pinned Geyser sneak forwarding"
)

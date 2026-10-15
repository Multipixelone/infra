"""Pinned gameplay plugins, effective permissions and disposable Paper startup."""

import gzip
import json
import pathlib
import re
import resource
import shutil
import subprocess
import sys
import tempfile
import zipfile

import yaml

fixture = json.loads(pathlib.Path(sys.argv[1]).read_text())
artifacts = fixture["artifacts"]
plugins = {
    "doubledoors": ("DoubleDoors", "1.4.9"),
    "axiom": ("AxiomPaper", "6.0.1+26.3"),
    "crazyenchantments": ("CrazyEnchantments", "26.3-ed9d9ab"),
}
folders = {
    "doubledoors": "DoubleDoors",
    "axiom": "Axiom",
    "crazyenchantments": "CrazyEnchantments",
}
grants = [
    "axiom.use",
    "axiom.editor.*",
    "axiom.build.*",
    "axiom.tool.*",
    "axiom.builder_tool.*",
    "axiom.chunk.*",
    "axiom.can_import_blocks",
    "axiom.can_export_blocks",
]
denials = [
    "axiom.world.time",
    "axiom.world.property",
    "axiom.player.teleport",
    "axiom.player.bypass_movement_restrictions",
    "axiom.capability.infinite_reach",
    "axiom.capability.no_clip",
    "axiom.capability.phantom",
    "axiom.capability.fast_place",
    "axiom.entity.*",
    "axiom.build_dangerous.*",
    "axiom.player.gamemode.*",
]
descriptors = {}
for key, (name, version) in plugins.items():
    with zipfile.ZipFile(artifacts[f"games-{key}"]) as jar:
        descriptor = yaml.safe_load(jar.read("plugin.yml"))
        assert descriptor["name"] == name and descriptor["version"] == version
        assert not descriptor.get("depend") and not descriptor.get("libraries")
        descriptors[key] = descriptor
        if key != "doubledoors":
            assert descriptor["api-version"] == "26.3"

axiom_nodes = descriptors["axiom"]["permissions"]
declared = set(axiom_nodes)
for value in axiom_nodes.values():
    declared.update(value.get("children", {}))
assert set(grants + denials) <= declared
assert set(
    descriptors["crazyenchantments"]["permissions"]["crazyenchantments.player.*"][
        "children"
    ]
) == {
    "crazyenchantments.tinker",
    "crazyenchantments.blacksmith",
    "crazyenchantments.gkitz",
    "crazyenchantments.gui",
    "crazyenchantments.limit",
    "crazyenchantments.info",
}
assert {"Geyser-Spigot", "floodgate"} <= set(descriptors["doubledoors"]["softdepend"])

bootstrap = json.loads(gzip.decompress(pathlib.Path(fixture["bootstrap"]).read_bytes()))
rank_nodes = {
    rank: {node["key"]: node["value"] for node in group["nodes"]}
    for rank, group in bootstrap["groups"].items()
}
assert all(
    rank_nodes["default"][node]
    for node in ("doubledoors.use", "doubledoors.toggle", "crazyenchantments.player.*")
)
assert {
    key
    for key, value in rank_nodes["builder"].items()
    if key.startswith("axiom.") and value
} == set(grants)
assert all(rank_nodes["builder"][node] is False for node in denials)
assert not any(
    key.startswith("axiom.") and value for key, value in rank_nodes["default"].items()
)
assert (
    "axiom.default" not in rank_nodes["builder"]
    and "axiom.all" not in rank_nodes["builder"]
)
assert rank_nodes["admin"]["*"]

for case in fixture["fixtures"].values():
    for server_id, backend in case["backends"].items():
        server = case["servers"][server_id]
        inventory = {entry["name"]: entry for entry in backend["inventory"]}
        for key, (name, version) in plugins.items():
            assert backend["jars"][key] == artifacts[f"games-{key}"]
            assert server["symlinks"][f"plugins/{key}.jar"] == artifacts[f"games-{key}"]
            assert (
                inventory[name]["installed"] and inventory[name]["version"] == version
            )
            assert (
                f"/srv/games/minecraft/{server_id}/plugins/{folders[key]}"
                in server["worldPaths"]
            )
            assert key not in case["proxyJars"]
        assert "floodgate" not in backend["jars"] and "geyser" not in backend["jars"]
        assert (
            server["symlinks"]["plugins/AxiomPaper"]
            == f"/srv/games/minecraft/{server_id}/plugins/Axiom"
        )
assert fixture["fixtures"]["noPaper"]["backends"] == {}

backend = fixture["fixtures"]["withLuckPerms"]["backends"]["survival"]


def configuration(folder, filename="config.yml"):
    path = f"/srv/games/minecraft/survival/plugins/{folder}/{filename}"
    return yaml.safe_load(
        pathlib.Path(backend["templates"][path]["source"]).read_text()
    )


doors = configuration("DoubleDoors")
assert doors["serverWideEnabled"] and doors["enableDoors"]
assert not any(
    doors[key]
    for key in (
        "enableRecursiveOpening",
        "enableFenceGates",
        "enableTrapdoors",
        "enableAutoClose",
        "enableAnonymousTracking",
    )
)
assert doors["interactionCooldownMillis"] == 250
assert not doors["sql"]["enabled"] and not doors["updateChecker"]["enabled"]
axiom = configuration("Axiom")
assert axiom["whitelist-world-regex"] == "^world$"
for world in ("world_nether", "world_the_end", "other", "world_copy"):
    assert not re.fullmatch(axiom["whitelist-world-regex"], world)
assert axiom["block-buffer-rate-limit"] == 2
assert axiom["max-chunk-load-distance"] == 0
assert axiom["max-chunk-sends-per-tick"] == axiom["max-chunk-relights-per-tick"] == 2
assert not any(
    axiom[key]
    for key in (
        "blueprint-sharing",
        "allow-annotations",
        "allow-large-chunk-data-request",
        "allow-large-payload-for-all-packets",
    )
)
assert {
    f"minecraft:{name}"
    for name in (
        "bedrock",
        "barrier",
        "command_block",
        "chain_command_block",
        "repeating_command_block",
        "structure_block",
        "structure_void",
        "jigsaw",
        "spawner",
        "trial_spawner",
        "end_portal_frame",
    )
} <= set(axiom["disallowed-blocks"])
with zipfile.ZipFile(artifacts["games-axiom"]) as jar:
    assert axiom.keys() == yaml.safe_load(jar.read("config.yml")).keys()
ce = configuration("CrazyEnchantments")
options = ce["Settings"]["EnchantmentOptions"]
assert (
    not options["UnSafe-Enchantments"] and not options["Right-Click-Enchantment-Table"]
)
assert options["Limit"]["Default-Limit"] == 3
assert not ce["Settings"]["Toggle-Metrics"]
for name, cost in ce["Settings"]["Costs"].items():
    if cost["Currency"] == "Vault":
        section = (
            ce["Settings"]["Dust"][name]
            if name in ("SuccessDust", "DestroyDust")
            else ce["Settings"][name]
        )
        assert not section["InGUI"], name
for category in ce["Categories"].values():
    assert category["InGUI"] and category["Currency"] == "XP_Level"
    assert not category["LostBook"]["InGUI"]
with zipfile.ZipFile(artifacts["games-crazyenchantments"]) as jar:
    defaults = yaml.safe_load(jar.read("Enchantments.yml"))
    actual = configuration("CrazyEnchantments", "Enchantments.yml")
    for name in ("VeinMiner", "Blast"):
        defaults["Enchantments"][name]["Enabled"] = False
    assert actual == defaults, "preserve unrelated enchantments, including TreeFeller"

# Verify both forwarding paths against the exact pinned Velocity implementation.
velocity = str(pathlib.Path(artifacts["games-velocity"]) / "lib/minecraft/server.jar")
for side in ("client.ClientPlaySessionHandler", "backend.BackendPlaySessionHandler"):
    code = subprocess.check_output(
        [
            "javap",
            "-c",
            "-p",
            "-classpath",
            velocity,
            f"com.velocitypowered.proxy.connection.{side}",
        ],
        text=True,
    )
    method = re.search(
        r"public boolean handle\(com.velocitypowered.proxy.protocol.packet.PluginMessagePacket\);(.*?)(?=\n  (?:public|private|protected))",
        code,
        re.DOTALL,
    ).group(1)
    branch = method[method.index("getFromId:") :]
    assert "ifnonnull" in branch
    if side.startswith("backend"):
        assert re.search(r"ifnonnull.*?iconst_0\s+\d+: ireturn", branch, re.DOTALL)
    else:
        assert (
            "PluginMessagePacket.retain" in branch
            and "MinecraftConnection.write" in branch
        )

with tempfile.TemporaryDirectory(prefix="minecraft-additions-") as directory:
    root = pathlib.Path(directory)
    (root / "cache").mkdir()
    shutil.copyfile(fixture["vanilla"], root / "cache/mojang_26.3.jar")
    (root / "eula.txt").write_text("eula=true\n")
    (root / "server.properties").write_text(
        "online-mode=false\nwhite-list=false\nserver-ip=127.0.0.1\nserver-port=0\n"
        "enable-rcon=false\nenable-query=false\nview-distance=2\nsimulation-distance=2\n"
        "pause-when-empty-seconds=-1\nlevel-type=minecraft:flat\n"
        'generator-settings={"layers":[{"block":"minecraft:bedrock","height":1}],"biome":"minecraft:plains","features":false,"lakes":false}\n'
    )
    (root / "config").mkdir()
    (root / "config/paper-global.yml").write_text(
        "spark:\n  enabled: false\n  enable-immediately: false\n"
    )
    # Nix's sandbox has no /sys. OSHI otherwise logs linkage errors while
    # Paper initializes crash-report hardware details, before any plugin loads.
    # An empty, existing sys root gives that optional probe unavailable data.
    sysroot = root / "sys"
    sysroot.mkdir()

    def run(argv, timeout=240):
        result = subprocess.run(
            argv,
            check=False,
            cwd=root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )
        if result.returncode:
            raise AssertionError(
                f"{argv!r} exited {result.returncode}\n{result.stdout}"
            )
        return result.stdout

    run(["java", "-Dpaperclip.patchonly=true", "-jar", fixture["paper"]])
    (root / "plugins").mkdir()
    for key in (*plugins, "fawe", "veinminer", "vault"):
        shutil.copyfile(artifacts[f"games-{key}"], root / f"plugins/{key}.jar")
    shutil.copyfile(artifacts["games-luckperms-paper"], root / "plugins/luckperms.jar")
    shutil.copytree(
        artifacts["games-veinminer-libraries"], root / "libraries", dirs_exist_ok=True
    )
    shutil.copytree(
        artifacts["games-luckperms-libraries"], root / "plugins/LuckPerms/libs"
    )
    for path, template in backend["templates"].items():
        relative = path.removeprefix("/srv/games/minecraft/survival/")
        if relative.startswith(
            tuple(
                f"plugins/{name}/"
                for name in (
                    *folders.values(),
                    "FastAsyncWorldEdit",
                    "Veinminer",
                    "bStats",
                )
            )
        ):
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(template["source"], destination)
    # Match the production alias; do not accidentally test an unused config.
    (root / "plugins/AxiomPaper").symlink_to("Axiom", target_is_directory=True)
    (root / "plugins/LuckPerms/config.yml").write_text(
        "storage-method: json\nmessaging-service: none\nauto-install-translations: false\n"
    )
    (root / "plugins/Vault").mkdir(exist_ok=True)
    (root / "plugins/Vault/config.yml").write_text("update-check: false\n")
    classpath = ":".join(
        map(
            str,
            [
                *sorted((root / "libraries").rglob("*.jar")),
                *sorted((root / "versions").rglob("*.jar")),
                *sorted((root / "plugins").glob("*.jar")),
            ],
        )
    )
    classes = root / "probe"
    classes.mkdir()
    source = root / "MinecraftAdditionsProbe.java"
    shutil.copyfile(sys.argv[2], source)
    run(["javac", "-cp", classpath, "-d", str(classes), str(source)])
    (classes / "plugin.yml").write_text(
        "name: MinecraftAdditionsProbe\nversion: '1'\nmain: MinecraftAdditionsProbe\n"
        "api-version: '26.3'\ndepend: [LuckPerms, DoubleDoors, AxiomPaper, CrazyEnchantments]\n"
    )
    (classes / "bootstrap.json").write_text(json.dumps(bootstrap))
    (classes / "expectations.json").write_text(
        json.dumps({"grants": grants, "denials": denials})
    )
    with zipfile.ZipFile(root / "plugins/probe.jar", "w") as jar:
        for path in classes.rglob("*"):
            if path.is_file():
                jar.write(path, path.relative_to(classes))
    output = run(
        [
            "java",
            "-Dterminal.jline=false",
            "-Dterminal.ansi=false",
            f"-Doshi.util.sys.path={sysroot}",
            "-Xms256M",
            "-Xmx2G",
            "-jar",
            fixture["paper"],
            "--nogui",
        ]
    )
    failures = [
        line
        for line in output.splitlines()
        if re.search(
            r"ADDITIONS_PROBE_FAIL|Error occurred while (?:enabling|disabling)|Could not load.*plugin|"
            r"Error loading.*plugin|NoClassDefFoundError|NoSuchMethodError|InvalidPluginException",
            line,
        )
    ]
    plugin_errors = [
        line
        for line in output.splitlines()
        if "ERROR" in line
        and any(
            name in line
            for name in (
                "DoubleDoors",
                "Axiom",
                "CrazyEnchantments",
                "MinecraftAdditionsProbe",
            )
        )
    ]
    if failures or plugin_errors or "ADDITIONS_PROBE_PASS" not in output:
        raise AssertionError(f"{failures + plugin_errors}\n{output}")
    print(output)
    # Linux ru_maxrss is KiB; this includes the disposable child JVM, not the
    # production cgroup and not a representative multiplayer edit workload.
    print(
        f"Disposable child peak RSS: {resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024:.0f} MiB"
    )
    print(
        "PASS: all three plugins on Paper 26.3 build 159, effective rank policy and runtime restrictions"
    )

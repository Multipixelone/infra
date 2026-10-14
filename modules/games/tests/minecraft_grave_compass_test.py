"""Ownership/respawn contracts and function parsing on the pinned, temporary Paper."""

import hashlib
import json
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zipfile
from pathlib import Path

PACK, PAPER, VANILLA = map(Path, sys.argv[1:])
PREFIX = "data/infra/function/grave_compass/"
OWNED = "minecraft:recovery_compass[minecraft:custom_data~{infra_grave_compass:1b}]"
with zipfile.ZipFile(PACK) as archive:
    FILES = {name: archive.read(name).decode() for name in archive.namelist()}


def commands(name):
    return [
        line
        for line in FILES[f"{PREFIX}{name}.mcfunction"].splitlines()
        if line and not line.startswith("#")
    ]


class GraveCompassContracts(unittest.TestCase):
    def test_format_matches_actual_server_and_bootstrap(self):
        with zipfile.ZipFile(VANILLA) as jar:
            version = json.loads(jar.read("version.json"))
        self.assertEqual(version["id"], "26.3")
        format_version = [
            version["pack_version"]["data_major"],
            version["pack_version"]["data_minor"],
        ]
        metadata = json.loads(FILES["pack.mcmeta"])["pack"]
        self.assertEqual(metadata["min_format"], format_version)
        self.assertEqual(metadata["max_format"], format_version)
        with zipfile.ZipFile(PAPER) as jar:
            digest, _, basename = (
                jar.read("META-INF/download-context").decode().strip().split("\t")
            )
        self.assertEqual(basename, "mojang_26.3.jar")
        self.assertEqual(hashlib.sha256(VANILLA.read_bytes()).hexdigest(), digest)

    def test_load_and_tick_references_resolve_without_reset_or_backfill(self):
        for tag, target in (("load", "load"), ("tick", "tick")):
            self.assertEqual(
                json.loads(FILES[f"data/minecraft/tags/function/{tag}.json"]),
                {"values": [f"infra:grave_compass/{target}"]},
            )
        self.assertEqual(
            commands("load"),
            [
                "scoreboard objectives add igc_deaths deathCount",
                "scoreboard objectives add igc_time minecraft.custom:minecraft.time_since_death",
                "scoreboard objectives add igc_items dummy",
            ],
        )
        self.assertEqual(
            commands("tick"),
            ["execute as @a at @s run function infra:grave_compass/player"],
        )
        for source in FILES.values():
            for target in re.findall(
                r"\bfunction (infra:grave_compass/[a-z_]+)", source
            ):
                self.assertIn(
                    f"data/infra/function/{target.split(':')[1]}.mcfunction", FILES
                )

    def test_pending_death_requires_alive_respawn_and_is_consumed_once(self):
        player = commands("player")
        self.assertEqual(
            player[0], "execute if entity @s[nbt={Health:0.0f}] run return 0"
        )
        self.assertEqual(
            player[1],
            "execute if score @s igc_deaths matches 1.. if score @s igc_time matches 1.. run function infra:grave_compass/respawn",
        )
        # >=1 handles delayed processing/reconnect; future deathCount prevents
        # historical grants. Consuming it also prevents replacement after arrival.
        self.assertEqual(
            commands("respawn")[-1], "scoreboard players set @s igc_deaths 0"
        )

    def test_duplicate_detection_is_nondestructive_and_only_owned_items_count(self):
        count = f"execute store result score @s igc_items run clear @s {OWNED} 0"
        self.assertIn(count, commands("player"))
        self.assertEqual(commands("respawn")[0], count)
        give = commands("respawn")[1]
        self.assertTrue(
            give.startswith(
                "execute if score @s igc_items matches 0 if data entity @s LastDeathLocation run give @s minecraft:recovery_compass["
            )
        )
        self.assertIn("minecraft:custom_data={infra_grave_compass:1b}", give)
        self.assertIn('minecraft:custom_name={text:"Grave Compass",italic:false}', give)
        self.assertIn(
            'minecraft:lore=[{text:"Points to your last death.",italic:false}]', give
        )
        self.assertTrue(give.endswith("]] 1"))

    def test_every_removal_targets_owned_recovery_compasses(self):
        clears = []
        for name, source in FILES.items():
            if not name.endswith(".mcfunction"):
                continue
            for line in source.splitlines():
                if line.startswith("#"):
                    continue
                if "clear " in line:
                    clears.append((name, line.split("clear ", 1)[1]))
                self.assertNotIn("kill ", line)
                self.assertNotIn("schedule ", line)
        self.assertEqual(len(clears), 3)
        for name, clear in clears:
            suffix = "" if name.endswith("/arrive.mcfunction") else " 0"
            self.assertEqual(clear, f"@s {OWNED}{suffix}")
        # A name alone, a crafted compass, another custom_data value, another
        # item with our marker, and loose entities must never be removal targets.

    def test_arrival_uses_latest_location_three_block_radius_and_same_dimension(self):
        self.assertEqual(
            commands("arrive"),
            [
                f"$execute if dimension $(dimension) positioned $(x) $(y) $(z) if entity @s[distance=..3] run clear @s {OWNED}",
            ],
        )
        self.assertEqual(
            commands("check_arrival")[0],
            "data modify storage infra:grave_compass death set from entity @s LastDeathLocation",
        )
        for index, axis in enumerate("xyz"):
            self.assertEqual(
                commands("check_arrival")[index + 1],
                f"data modify storage infra:grave_compass death.{axis} set from entity @s LastDeathLocation.pos[{index}]",
            )
        self.assertEqual(
            commands("check_arrival")[-1],
            "function infra:grave_compass/arrive with storage infra:grave_compass death",
        )
        self.assertEqual(
            commands("player")[-1],
            "execute if score @s igc_items matches 1.. if data entity @s LastDeathLocation run function infra:grave_compass/check_arrival",
        )


def parser_smoke():
    """Paper compiles functions on load, and macros only upon instantiation."""
    with tempfile.TemporaryDirectory(prefix="grave-compass-") as directory:
        root = Path(directory)
        cache = root / "cache"
        cache.mkdir()
        shutil.copyfile(VANILLA, cache / "mojang_26.3.jar")
        pack = root / "world/datapacks/grave-compass"
        pack.mkdir(parents=True)
        with zipfile.ZipFile(PACK) as archive:
            archive.extractall(pack)
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
        process = subprocess.Popen(
            ["java", "-Xms256M", "-Xmx1G", "-jar", str(PAPER), "--nogui"],
            cwd=root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        lines = []
        output = queue.Queue()

        def reader():
            for line in process.stdout:
                lines.append(line)
                output.put(line)
            output.put(None)

        thread = threading.Thread(target=reader, daemon=True)
        thread.start()

        def wait_for(fragment, timeout=180):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    line = output.get(timeout=max(0.01, deadline - time.monotonic()))
                except queue.Empty:
                    break
                if line is None:
                    raise AssertionError(f"Paper exited before {fragment!r}")
                if fragment in line:
                    return
            raise AssertionError(f"Paper did not report {fragment!r}")

        def send(command):
            process.stdin.write(command + "\n")
            process.stdin.flush()

        def compilation_failures():
            return [
                line
                for line in lines
                if re.search(
                    r"Failed to load function infra:grave_compass/|Failed to instantiate macro|Invalid macro|Unknown or incomplete command|Incorrect argument for command",
                    line,
                )
            ]

        try:
            wait_for("Done (")
            assert not compilation_failures(), compilation_failures()
            # No player is needed to instantiate/parse the macro. This also
            # tests all three dimensions, negative coordinates and world limits.
            for dimension, x, y, z in (
                ("overworld", 0, 64, 0),
                ("the_nether", -10, 32, -20),
                ("the_end", 29999980, -64, -29999980),
            ):
                send(
                    f'function infra:grave_compass/arrive {{dimension:"minecraft:{dimension}",x:{x},y:{y},z:{z}}}'
                )
            # /reload's load function must not reset pending deaths.
            send("scoreboard players set fixture igc_deaths 1")
            send("function infra:grave_compass/load")
            send(
                "execute if score fixture igc_deaths matches 1 run say INFRA_COMPASS_PENDING_PRESERVED"
            )
            wait_for("INFRA_COMPASS_PENDING_PRESERVED")
            assert not compilation_failures(), compilation_failures()
            # Prove this check detects a parser error even though Paper still
            # boots/reloads successfully with an invalid individual function.
            (pack / f"{PREFIX}invalid.mcfunction").write_text(
                "infra_deliberately_invalid_command\n"
            )
            send("reload")
            wait_for("Failed to load function infra:grave_compass/invalid")
            # The intentional error also emits unnamed stack-trace lines.
            failures = [
                line
                for line in compilation_failures()
                if "Failed to load function " in line
            ]
            assert (
                len(failures) == 1 and "infra:grave_compass/invalid" in failures[0]
            ), failures
            send("stop")
            assert process.wait(timeout=60) == 0
            print(
                "PASS: Paper 26.3 compiled grave compass functions/macros; pending scores survive load; invalid fixture detected"
            )
        except BaseException:
            print("".join(lines), file=sys.stderr)
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            thread.join(timeout=5)


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(GraveCompassContracts)
    if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
        sys.exit(1)
    parser_smoke()

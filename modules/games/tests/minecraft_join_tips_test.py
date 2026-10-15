"""Private join output contracts and behavior on disposable pinned Paper players."""

import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

PACK, PAPER, VANILLA, PROBE = map(Path, sys.argv[1:])
PREFIX = "data/infra/function/join_tips/"
with zipfile.ZipFile(PACK) as archive:
    FILES = {name: archive.read(name).decode() for name in archive.namelist()}


def commands(name):
    return [
        line
        for line in FILES[f"{PREFIX}{name}.mcfunction"].splitlines()
        if line and not line.startswith("#")
    ]


def components(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from components(child)
    elif isinstance(value, list):
        for child in value:
            yield from components(child)


def plain(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "".join(map(plain, value))
    return (
        value.get("text", "")
        + ("@s" if "selector" in value else "")
        + plain(value.get("extra", []))
    )


def messages(name):
    return [
        json.loads(line.removeprefix("tellraw @s "))
        for line in commands(name)
        if line.startswith("tellraw @s ")
    ]


TIPS = [plain(messages(f"tips/{index}")[0]) for index in range(1, 21)]
WELCOME = plain(messages("first")[0])


class JoinTipsContracts(unittest.TestCase):
    def test_historical_saved_stat_predicate_uses_26_3_type_discriminators(self):
        predicate = json.loads(FILES["data/infra/predicate/join_tips/returning.json"])
        self.assertEqual(predicate["type"], "minecraft:any_of")
        stats = []
        for term in predicate["terms"]:
            self.assertEqual(term["type"], "minecraft:entity_properties")
            self.assertEqual(term["entity"], "this")
            self.assertEqual(
                list(term["predicate"]), ["minecraft:type_specific/player"]
            )
            player = term["predicate"]["minecraft:type_specific/player"]
            stats.extend(player["stats"])
        self.assertEqual(
            stats,
            [
                {
                    "type": "minecraft:custom",
                    "stat": "minecraft:play_time",
                    "value": {"min": 1},
                },
                {
                    "type": "minecraft:custom",
                    "stat": "minecraft:leave_game",
                    "value": {"min": 1},
                },
            ],
        )

    def test_exactly_twenty_single_line_private_tips_and_six_welcome_lines(self):
        tip_files = [name for name in FILES if name.startswith(PREFIX + "tips/")]
        self.assertEqual(len(tip_files), 20)
        self.assertEqual(len(set(TIPS)), 20)
        for tip in TIPS:
            self.assertTrue(tip.startswith("· Tip: "), tip)
            self.assertNotIn("\n", tip)
        self.assertEqual(len(WELCOME.splitlines()), 6)
        self.assertTrue(
            WELCOME.startswith("· Welcome to Finn's Survival! Quick start:")
        )
        self.assertEqual(len(messages("returning")), 1)
        self.assertEqual(plain(messages("returning")[0]), "· Welcome back, @s!")
        self.assertEqual(len(messages("first")), 1)

    def test_actual_pinned_pack_version_and_bootstrap(self):
        with zipfile.ZipFile(VANILLA) as jar:
            version = json.loads(jar.read("version.json"))
        self.assertEqual(version["id"], "26.3")
        pack_version = [
            version["pack_version"]["data_major"],
            version["pack_version"]["data_minor"],
        ]
        metadata = json.loads(FILES["pack.mcmeta"])["pack"]
        self.assertEqual(metadata["min_format"], pack_version)
        self.assertEqual(metadata["max_format"], pack_version)
        with zipfile.ZipFile(PAPER) as jar:
            digest, _, basename = (
                jar.read("META-INF/download-context").decode().strip().split("\t")
            )
        self.assertEqual(basename, "mojang_26.3.jar")
        self.assertEqual(hashlib.sha256(VANILLA.read_bytes()).hexdigest(), digest)

    def test_only_self_delivery_no_ticker_and_references_resolve(self):
        delivery = 0
        for name, source in FILES.items():
            if not name.endswith(".mcfunction"):
                continue
            for line in source.splitlines():
                if line.startswith("#"):
                    continue
                if "tellraw " in line:
                    self.assertTrue(line.startswith("tellraw @s "), (name, line))
                    self.assertNotIn("@a", line)
                    delivery += 1
                self.assertIsNone(
                    re.search(
                        r"\b(say|msg|tell|w|schedule)\b", line.split("tellraw", 1)[0]
                    ),
                    line,
                )
            for target in re.findall(
                r"\bfunction (infra:join_tips/[a-z0-9_/]+)", source
            ):
                self.assertIn(
                    "data/infra/function/" + target.split(":")[1] + ".mcfunction", FILES
                )
        self.assertEqual(delivery, 22)
        self.assertEqual(
            commands("load"),
            [
                "scoreboard objectives add ijt_leave minecraft.custom:minecraft.leave_game",
                "scoreboard objectives add ijt_tip dummy",
            ],
        )
        self.assertIn("random value 1..20", "\n".join(commands("returning")))
        for tag in ("load", "tick"):
            self.assertEqual(
                json.loads(FILES[f"data/minecraft/tags/function/{tag}.json"]),
                {"values": [f"infra:join_tips/{tag}"]},
            )

    def test_content_includes_requested_features_and_exclusions(self):
        all_tips = "\n".join(TIPS)
        for required in (
            "/edithome <name> privacy public",
            "/phome <player>:<home>",
            "/tpa <player>",
            "/nick <aqua>Name",
            "/nick reset",
            "/rtp",
            "10 minutes",
        ):
            self.assertIn(required, all_tips)
        for excluded in (
            "/skin",
            "/spawn",
            "/msg",
            "/warp",
            "Distant Horizons",
            "Voice Chat",
            "/graves tp",
        ):
            self.assertNotIn(excluded, all_tips)

    def test_shared_exact_palette_and_interactions(self):
        for name in (
            "first",
            "returning",
            *(f"tips/{index}" for index in range(1, 21)),
        ):
            for message in messages(name):
                root = message[0] if isinstance(message, list) else message
                self.assertEqual(root["color"], "#a6adc8")
                for part in components(message):
                    if "color" in part:
                        self.assertRegex(part["color"], r"^#[0-9a-f]{6}$")
                    click = part.get("click_event", part.get("clickEvent"))
                    if click:
                        self.assertIn(click["action"], ("suggest_command", "open_url"))
                        self.assertIn("hover_event", part)
        nickname = next(message for message in TIPS if "/nick " in message)
        self.assertIn("Linked Discord nicknames sync as plain text", nickname)


def runtime_check():
    """Bootstrap offline, compile the probe against the exact runtime, then boot twice."""
    with tempfile.TemporaryDirectory(prefix="join-tips-") as directory:
        root = Path(directory)
        (root / "cache").mkdir()
        shutil.copyfile(VANILLA, root / "cache/mojang_26.3.jar")
        (root / "eula.txt").write_text("eula=true\n")
        (root / "config").mkdir()
        (root / "config/paper-global.yml").write_text(
            "spark:\n  enabled: false\n  enable-immediately: false\n"
        )
        (root / "server.properties").write_text(
            "online-mode=false\nwhite-list=false\nserver-ip=127.0.0.1\nserver-port=0\n"
            "enable-rcon=false\nenable-query=false\nview-distance=2\nsimulation-distance=2\n"
            "pause-when-empty-seconds=-1\nlevel-type=minecraft:flat\n"
            'generator-settings={"layers":[{"block":"minecraft:bedrock","height":1}],"biome":"minecraft:plains","features":false,"lakes":false}\n'
        )
        pack = root / "world/datapacks/join-tips"
        pack.mkdir(parents=True)
        with zipfile.ZipFile(PACK) as archive:
            archive.extractall(pack)

        def run(argv, timeout=180):
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

        run(["java", "-Dpaperclip.patchonly=true", "-jar", str(PAPER)])
        classpath = ":".join(
            map(
                str,
                sorted((root / "libraries").rglob("*.jar"))
                + sorted((root / "versions").rglob("*.jar")),
            )
        )
        classes = root / "probe"
        classes.mkdir()
        source = root / "JoinTipsProbe.java"
        shutil.copyfile(PROBE, source)
        run(["javac", "-cp", classpath, "-d", str(classes), str(source)])
        (classes / "plugin.yml").write_text(
            "name: JoinTipsProbe\nversion: '1'\nmain: JoinTipsProbe\napi-version: '26.3'\n"
        )
        gradient_colors = [
            part["color"]
            for part in components(messages("first")[0])
            if part.get("bold") is True
        ]
        (classes / "expectations.json").write_text(
            json.dumps(
                {
                    "tips": TIPS,
                    "welcome": WELCOME,
                    "gradient_colors": gradient_colors,
                    "welcome_events": sum(
                        "click_event" in part
                        for part in components(messages("first")[0])
                    ),
                    "tip_events": [
                        sum(
                            "click_event" in part
                            for part in components(messages(f"tips/{index}")[0])
                        )
                        for index in range(1, 21)
                    ],
                }
            )
        )
        (root / "plugins").mkdir(exist_ok=True)
        with zipfile.ZipFile(root / "plugins/JoinTipsProbe.jar", "w") as archive:
            for file in classes.iterdir():
                archive.write(file, file.name)
        for phase in ("ONE", "TWO"):
            output = run(
                ["java", "-Xms256M", "-Xmx1G", "-jar", str(PAPER), "--nogui"],
                timeout=240,
            )
            errors = re.findall(
                r"Failed to load function infra:join_tips/.*|Unknown or incomplete command.*|Incorrect argument for command.*|JOIN_TIPS_PROBE_FAIL",
                output,
            )
            if errors or f"JOIN_TIPS_PHASE_{phase}_PASS" not in output:
                raise AssertionError(
                    f"Pinned Paper phase {phase} failed: {errors}\n{output}"
                )
            print(f"PASS: pinned Paper 26.3 join-tip behavior phase {phase}")


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(JoinTipsContracts)
    if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
        sys.exit(1)
    runtime_check()

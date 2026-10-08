"""Run the real launcher with a fixture runner; never touch live beets data."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

LAUNCHER = sys.argv.pop(1)


class WindowTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.args = self.root / "args.json"
        self.env = os.environ | {
            "PATH": str(self.bin) + ":" + os.environ["PATH"],
            "BEETS_EMBED_BUDGET_SECONDS": "28800",
            "BEETS_EMBED_THREADS": "2",
            "BEETS_EMBED_CONFIG": str(self.root / "config.json"),
            "BEETS_EMBED_RUNNER": str(self.bin / "runner"),
            "FIXTURE_ARGS": str(self.args),
            "CLOCK_NOW": "1000",
            "CLOCK_START": "1000",
            "CLOCK_STOP": "29740",
        }
        self.tool(
            "date",
            "import os,sys\n"
            "key = 'CLOCK_NOW' if sys.argv[1:] == ['+%s'] else "
            "('CLOCK_START' if '00:00:00' in sys.argv[1] else 'CLOCK_STOP')\n"
            "print(int(os.environ[key]) - (3600 if key == 'CLOCK_START' else 0))\n",
        )
        self.tool(
            "timeout",
            "import json,os,sys\n"
            "from pathlib import Path\n"
            "Path(os.environ['FIXTURE_ARGS']).write_text(json.dumps(sys.argv[1:]))\n",
        )

    def tool(self, name, source):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o700)

    def run_launcher(self, mode=None, **env):
        # writeShellApplication prefixes PATH; running its body keeps fixture
        # tools ahead of runtimeInputs while exercising the identical shell code.
        source = Path(LAUNCHER).read_text()
        body = source[source.index("export TZ=America/New_York") :]
        return subprocess.run(
            [shutil.which("bash"), "-eu", "-o", "pipefail", "-c", body, "launcher"]
            + ([] if mode is None else [mode]),
            env=self.env | env,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )

    def test_budget_and_shutdown_grace(self):
        self.assertEqual(self.run_launcher().returncode, 0)
        args = json.loads(self.args.read_text())
        self.assertEqual(args[:3], ["--signal=TERM", "--kill-after=60s", "28740s"])
        self.assertEqual(args[-2:], ["--threads", "2"])

    def test_smaller_budget_and_late_start(self):
        self.run_launcher(BEETS_EMBED_BUDGET_SECONDS="7200")
        self.assertEqual(json.loads(self.args.read_text())[2], "7140s")
        self.run_launcher(CLOCK_NOW="29700")
        self.assertEqual(json.loads(self.args.read_text())[2], "40s")

    def test_replacement_cpu_thread_budget(self):
        self.assertEqual(self.run_launcher(BEETS_EMBED_THREADS="10").returncode, 0)
        self.assertEqual(json.loads(self.args.read_text())[-2:], ["--threads", "10"])

    def test_outside_window_skips_all_work(self):
        for now in ("999", "29740", "40000"):
            result = self.run_launcher(CLOCK_NOW=now)
            self.assertEqual(result.returncode, 0)
            self.assertIn("Outside", result.stdout)
            self.assertFalse(self.args.exists())

    def test_manual_ignores_calendar_but_preserves_budget(self):
        for now in ("999", "29740", "40000"):
            with self.subTest(now=now):
                result = self.run_launcher(mode="now", CLOCK_NOW=now)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(self.args.read_text())[2], "28740s")
        self.run_launcher(mode="now", BEETS_EMBED_BUDGET_SECONDS="7200")
        self.assertEqual(json.loads(self.args.read_text())[2], "7140s")

    def test_unknown_mode_fails_without_work(self):
        self.assertEqual(self.run_launcher(mode="invalid").returncode, 2)
        self.assertFalse(self.args.exists())

    def test_dst_uses_wall_clock_cutoff_and_elapsed_ceiling(self):
        date = shutil.which("date")
        for day, expected in (("2026-03-08", 25140), ("2026-11-01", 28740)):
            epochs = [
                subprocess.check_output(
                    [date, "--date=" + day + " " + clock, "+%s"],
                    env=os.environ | {"TZ": "America/New_York"},
                    text=True,
                ).strip()
                for clock in ("01:00:00", "08:59:00")
            ]
            self.run_launcher(
                CLOCK_NOW=epochs[0], CLOCK_START=epochs[0], CLOCK_STOP=epochs[1]
            )
            self.assertEqual(json.loads(self.args.read_text())[2], f"{expected}s")


if __name__ == "__main__":
    unittest.main()

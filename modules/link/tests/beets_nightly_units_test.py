"""Check evaluated nightly units without starting services or touching music."""

import configparser
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CASES = json.loads(Path(sys.argv.pop(1)).read_text())


def unit(case, name):
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.optionxform = str
    parser.read_string(case["units"][name])
    return parser


class NightlyUnitsTest(unittest.TestCase):
    def test_shared_budget_and_direct_batch_child(self):
        for name, case in CASES.items():
            with self.subTest(case=name):
                self.assertEqual(case["beetsSlices"], ["batch-beets"])
                self.assertEqual(case["workers"], 12)
                self.assertEqual(case["threads"], 4)
                quotas = (700, 300) if name == "quotaOverrides" else (800, 400)
                shared = case["slices"]["batch-beets"]
                self.assertEqual(shared["CPUQuota"], f"{sum(quotas)}%")
                self.assertEqual(shared["CPUWeight"], 10)
                self.assertEqual(shared["IOWeight"], 10)
                if name == "memoryHigh":
                    self.assertEqual(shared["MemoryHigh"], "8G")
                else:
                    self.assertNotIn("MemoryHigh", shared)
                parent = case["slices"]["batch"]
                self.assertEqual(parent["CPUWeight"], 20)
                self.assertEqual(parent["IOWeight"], 20)
                for sibling in ("batch", "batch-nix"):
                    self.assertNotIn("CPUQuota", case["slices"][sibling])
                    self.assertNotIn("MemoryHigh", case["slices"][sibling])
                    self.assertNotIn("MemoryMax", case["slices"][sibling])
                ci = case["slices"]["batch-ci"]
                self.assertEqual(ci["MemoryHigh"], "8G")
                self.assertEqual(ci["MemoryMax"], "12G")
                for job, quota in zip(
                    ("beets-xtractor-backfill", "beets-embed-backfill"), quotas
                ):
                    if job not in case["jobs"]:
                        continue
                    service = unit(case, job + ".service")["Service"]
                    self.assertEqual(service["Slice"], "batch-beets.slice")
                    self.assertEqual(service["CPUQuota"], f"{quota}%")
                    self.assertEqual(service["CPUWeight"], "10")
                    self.assertEqual(service["User"], "tunnel")
                    self.assertEqual(service["KillMode"], "control-group")
                    self.assertEqual(service["TimeoutStopSec"], "60s")
                    self.assertEqual(service["RuntimeMaxSec"], "8h")

    def test_target_keeps_group_lifecycle(self):
        for name, case in CASES.items():
            with self.subTest(case=name):
                expected = ["beets-xtractor-backfill"]
                if name != "embedDisabled":
                    expected.append("beets-embed-backfill")
                self.assertEqual(case["jobs"], expected)
                target = unit(case, "beets-nightly.target")["Unit"]
                self.assertEqual(target["StopWhenUnneeded"], "true")
                self.assertEqual(
                    set(target["Wants"].split()),
                    {job + ".service" for job in expected},
                )
                for job in expected:
                    dependencies = unit(case, job + ".service")["Unit"]
                    self.assertIn(
                        "beets-nightly.target", dependencies["Requires"].split()
                    )
                    self.assertIn(
                        "beets-nightly.target", dependencies["PartOf"].split()
                    )
                    # Target default ordering follows its workers: the reverse
                    # ordering here would introduce a cycle.
                    self.assertNotIn(
                        "beets-nightly.target", dependencies.get("After", "").split()
                    )

    def test_start_and_cutoff_timers_are_unchanged(self):
        for name, case in CASES.items():
            with self.subTest(case=name):
                for job in case["jobs"]:
                    for suffix, clock in (
                        (".timer", "01:00:00"),
                        ("-stop.timer", "08:58:59"),
                    ):
                        timer = unit(case, job + suffix)
                        self.assertEqual(
                            timer["Timer"]["OnCalendar"],
                            f"*-*-* {clock} America/New_York",
                        )
                        self.assertEqual(timer["Timer"]["Persistent"], "false")
                        self.assertEqual(timer["Timer"]["AccuracySec"], "1s")
                        self.assertEqual(timer["Timer"]["RandomizedDelaySec"], "0")
                        self.assertIn(
                            "timers.target", timer["Install"]["WantedBy"].split()
                        )
                    stop = unit(case, job + "-stop.service")["Service"]
                    self.assertTrue(
                        stop["ExecStart"].endswith(" stop " + job + ".service")
                    )
                    self.assertEqual(stop["TimeoutStartSec"], "90s")

    def test_offline_systemd_graph(self):
        noop = shutil.which("true")
        self.assertIsNotNone(noop)
        for name, case in CASES.items():
            with (
                self.subTest(case=name),
                tempfile.TemporaryDirectory(prefix="beets-nightly-units-") as directory,
            ):
                root = Path(directory)
                for filename, text in case["units"].items():
                    # Replace executable paths only. Keep the evaluated unit
                    # dependencies and resource settings; verify never starts them.
                    text = re.sub(
                        r"^ExecStart=.*$",
                        lambda _: f"ExecStart={noop}",
                        text,
                        flags=re.MULTILINE,
                    )
                    (root / filename).write_text(text)
                for filename in (
                    "sysinit.target",
                    "basic.target",
                    "shutdown.target",
                    "timers.target",
                    "system.slice",
                ):
                    (root / filename).write_text("[Unit]\nDefaultDependencies=no\n")
                (root / "systemd-tmpfiles-setup.service").write_text(
                    "[Unit]\nDefaultDependencies=no\n[Service]\n"
                    f"Type=oneshot\nExecStart={noop}\n"
                )
                result = subprocess.run(
                    [
                        "systemd-analyze",
                        "verify",
                        "--man=no",
                        *[str(root / filename) for filename in case["units"]],
                    ],
                    env=os.environ | {"SYSTEMD_UNIT_PATH": str(root)},
                    capture_output=True,
                    text=True,
                    check=False,
                    timeout=15,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""Exercise CPU policies against fake sysfs/topologies, never the live host."""

import runpy
import shlex
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


def source_argument(default_name):
    if len(sys.argv) > 1:
        return Path(sys.argv.pop(1))
    return Path(__file__).resolve().parents[3] / "lib" / default_name


CI_SOURCE = source_argument("link-ci-cpus.nix")
EPP_SOURCE = source_argument("link-cpu-idle-policy.nix")


def body(path):
    return path.read_text().strip()[2:-2].replace("''${", "${")


def run(script):
    return subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )


class SourceArgumentTest(unittest.TestCase):
    def test_explicit_sources_do_not_require_repository_ancestry(self):
        with tempfile.TemporaryDirectory(dir="/tmp") as directory:
            shallow_path = Path(directory) / "cpu_policy_test.py"
            shallow_path.write_text(Path(__file__).read_text())
            with patch.object(
                sys, "argv", [str(shallow_path), str(CI_SOURCE), str(EPP_SOURCE)]
            ):
                namespace = runpy.run_path(str(shallow_path))
                self.assertEqual(namespace["CI_SOURCE"], CI_SOURCE)
                self.assertEqual(namespace["EPP_SOURCE"], EPP_SOURCE)
                self.assertEqual(sys.argv, [str(shallow_path)])


class TopologyTest(unittest.TestCase):
    def select(self, rows):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "topology"
            source.write_text("# CPU,Core,Socket,Online\n" + "\n".join(rows) + "\n")
            return run(
                f"lscpu() {{ cat {shlex.quote(str(source))}; }}\n" + body(CI_SOURCE)
            )

    def test_old_and_new_smt_spacing(self):
        for cores in (8, 16):
            with self.subTest(cores=cores):
                rows = [f"{cpu},{cpu % cores},0,Y" for cpu in range(cores * 2)]
                result = self.select(rows)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    result.stdout.strip(),
                    f"{cores - 2},{2 * cores - 2},{cores - 1},{2 * cores - 1}",
                )

    def test_noncontiguous_ids_and_sockets(self):
        result = self.select(
            ["9,0,0,Y", "4,0,0,Y", "17,1,2,Y", "3,1,2,Y", "50,9,2,Y", "41,9,2,Y"]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "17,3,50,41")

    def test_partially_offline_core_is_excluded(self):
        result = self.select(
            ["0,0,0,Y", "3,0,0,Y", "1,1,0,Y", "4,1,0,Y", "2,2,0,Y", "5,2,0,N"]
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0,3,1,4")

    def test_invalid_or_insufficient_topology_fails_without_mask(self):
        for rows in (
            [],
            ["0,0,0,Y", "1,0,0,Y"],
            ["0,0,0,Y", "0,1,0,Y"],
            ["0,0,0,Y", "1,1,0,Y", "unexpected"],
        ):
            with self.subTest(rows=rows):
                result = self.select(rows)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")


class EppTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.script = body(EPP_SOURCE).replace(
            "/sys/devices/system/cpu/cpufreq", str(self.root)
        )

    def policy(
        self,
        index,
        driver="amd-pstate-epp",
        governor="powersave",
        available="performance balance_performance balance_power power",
    ):
        path = self.root / f"policy{index}"
        path.mkdir()
        for name, value in {
            "scaling_driver": driver,
            "scaling_governor": governor,
            "energy_performance_available_preferences": available,
            "energy_performance_preference": "performance",
        }.items():
            (path / name).write_text(value + "\n")
        return path / "energy_performance_preference"

    def test_repeated_restoration_after_gamemode(self):
        paths = [self.policy(0), self.policy(16)]
        for _ in range(2):
            result = run(self.script)
            self.assertEqual(result.returncode, 0, result.stderr)
            for path in paths:
                self.assertEqual(path.read_text().strip(), "balance_performance")
                path.write_text("performance\n")

    def test_missing_cppc_fails(self):
        self.assertNotEqual(run(self.script).returncode, 0)

    def test_invalid_policy_never_partially_writes(self):
        for field, value in (
            ("driver", "acpi-cpufreq"),
            ("governor", "performance"),
            ("available", "performance balance_power"),
        ):
            with self.subTest(field=field):
                good = self.policy(0)
                bad = self.policy(1, **{field: value})
                self.assertNotEqual(run(self.script).returncode, 0)
                self.assertEqual(good.read_text().strip(), "performance")
                self.assertEqual(bad.read_text().strip(), "performance")
                for directory in self.root.iterdir():
                    for path in directory.iterdir():
                        path.unlink()
                    directory.rmdir()


if __name__ == "__main__":
    unittest.main()

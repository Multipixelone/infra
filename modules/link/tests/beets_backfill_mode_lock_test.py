"""Exercise the production admission wrapper using only temporary fixtures."""

import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

LAUNCHER = sys.argv.pop(1)
WORKER = """
import sys, time
from pathlib import Path
ready, release = map(Path, sys.argv[1:])
ready.touch()
while not release.exists():
    time.sleep(0.01)
"""


class ModeLockTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="beets-mode-lock-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.processes = []
        self.addCleanup(self.cleanup_processes)

    def cleanup_processes(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=5)

    def command(self, mode, marker):
        return [
            LAUNCHER,
            str(self.root),
            mode,
            sys.executable,
            "-c",
            WORKER,
            str(self.root / marker),
            str(self.root / (marker + "-release")),
        ]

    def start(self, mode, marker, wait=True):
        process = subprocess.Popen(
            self.command(mode, marker),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.processes.append(process)
        if wait:
            self.wait_for(lambda: (self.root / marker).exists(), process)
        return process

    def wait_for(self, condition, process=None):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if condition():
                return
            if process is not None and process.poll() is not None:
                self.fail(f"Worker exited early: {process.communicate()}")
            time.sleep(0.01)
        self.fail("Fixture did not become ready")

    def assert_skipped(self, mode):
        result = subprocess.run(
            self.command(mode, "skipped"),
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"skipping {mode} run", result.stdout)
        self.assertFalse((self.root / "skipped").exists())

    def test_same_mode_concurrency_and_opposite_mode_exclusion(self):
        for mode, opposite in (("nightly", "now"), ("now", "nightly")):
            with self.subTest(mode=mode):
                first = self.start(mode, mode + "-first")
                second = self.start(mode, mode + "-second")
                self.assert_skipped(opposite)
                (self.root / (mode + "-first-release")).touch()
                first.communicate(timeout=5)
                self.assertEqual(first.returncode, 0)
                self.assert_skipped(opposite)
                (self.root / (mode + "-second-release")).touch()
                second.communicate(timeout=5)
                self.assertEqual(second.returncode, 0)
                next_run = self.start(opposite, mode + "-next")
                next_run.terminate()
                next_run.communicate(timeout=5)

    def test_termination_releases_lock(self):
        first = self.start("now", "terminated")
        first.terminate()
        first.communicate(timeout=5)
        self.start("nightly", "after-termination")

    def test_descendant_retains_lock_after_launcher_exits(self):
        child = self.root / "child"
        shell = self.root / "spawn"
        # The worker is intentionally detached from the launcher process. Its
        # inherited descriptor must protect the mode until it exits too.
        shell.write_text(
            "#!/bin/sh\n"
            + f"{sys.executable} -c '{WORKER}' '{child}' '{child}-release' &\n"
        )
        shell.chmod(0o700)
        parent = subprocess.Popen(
            [LAUNCHER, str(self.root), "now", str(shell)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.assertEqual(parent.wait(timeout=5), 0)
        self.wait_for(child.exists)
        try:
            self.assert_skipped("nightly")
        finally:
            (self.root / "child-release").touch()
        # Admission succeeds once the inherited descriptor is closed.
        self.wait_for(
            lambda: (
                (
                    result := subprocess.run(
                        [LAUNCHER, str(self.root), "nightly", "true"],
                        capture_output=True,
                        text=True,
                        timeout=5,
                        check=False,
                    )
                ).returncode
                == 0
                and result.stdout == ""
            )
        )

    def test_simultaneous_admission_has_only_one_mode(self):
        gate = self.root / "gate"
        admission = """
import os, sys, time
from pathlib import Path
gate = Path(sys.argv[1])
while not gate.exists():
    time.sleep(0.001)
os.execv(sys.argv[2], sys.argv[2:])
"""
        for attempt in range(10):
            markers = [f"race-{attempt}-{mode}" for mode in ("nightly", "now")]
            gate.unlink(missing_ok=True)
            processes = [
                subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        admission,
                        str(gate),
                        *self.command(mode, marker),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                for mode, marker in zip(("nightly", "now"), markers)
            ]
            self.processes.extend(processes)
            gate.touch()
            self.wait_for(
                lambda processes=processes: any(p.poll() is not None for p in processes)
            )
            running = [i for i, p in enumerate(processes) if p.poll() is None]
            self.assertEqual(len(running), 1)
            winner = running[0]
            self.wait_for((self.root / markers[winner]).exists, processes[winner])
            loser = 1 - winner
            stdout, stderr = processes[loser].communicate(timeout=5)
            self.assertEqual(processes[loser].returncode, 0, stderr)
            self.assertIn("skipping", stdout)
            self.assertFalse((self.root / markers[loser]).exists())
            (self.root / (markers[winner] + "-release")).touch()
            processes[winner].communicate(timeout=5)


if __name__ == "__main__":
    unittest.main(verbosity=2)

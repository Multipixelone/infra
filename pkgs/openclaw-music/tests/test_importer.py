import fcntl
import logging
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from openclaw_music.errors import BackendTransient, BackendUncertain
from openclaw_music.importer import DirectBeetsImportAdapter

logger = logging.getLogger(__name__)


class ImportProcessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.adapter = DirectBeetsImportAdapter(
            sys.executable,
            str(self.root / "config.yaml"),
            str(self.root / ".import.lock"),
            str(self.root / "stage"),
            str(self.root / "library"),
            str(self.root),
            str(Path(sys.executable).parent),
            str(self.root / "cache"),
        )

    def test_import_gets_thirty_minutes_but_list_keeps_two(self):
        timeouts = []

        def runner(argv, **kwargs):
            timeouts.append(kwargs["timeout"])
            return subprocess.CompletedProcess(argv, 0, "", "")

        self.adapter.run = runner
        self.adapter._run_unlocked(["beet", "list"])
        self.adapter._run_unlocked(["beet", "import"], mutation=True)
        self.assertEqual(timeouts, [120, 1800])

    def test_lock_waits_without_starting_subprocess_timeout(self):
        entered, acquired = threading.Event(), threading.Event()
        calls, errors = [], []

        def runner(argv, **kwargs):
            calls.append(kwargs["timeout"])
            return subprocess.CompletedProcess(argv, 0, "", "")

        self.adapter.run = runner

        def import_behind_backfill():
            try:
                entered.set()
                with self.adapter._locked():
                    acquired.set()
                    self.adapter._run_unlocked(["beet", "import"], mutation=True)
            except BaseException as exc:
                logger.exception("Background import failed")
                errors.append(exc)

        with open(self.adapter.lock_path, "w") as backfill:
            fcntl.flock(backfill, fcntl.LOCK_EX)
            worker = threading.Thread(target=import_behind_backfill)
            worker.start()
            try:
                self.assertTrue(entered.wait(2))
                self.assertFalse(acquired.wait(0.1))
                self.assertEqual(calls, [])
            finally:
                fcntl.flock(backfill, fcntl.LOCK_UN)
                worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertTrue(acquired.is_set())
        self.assertEqual(errors, [])
        self.assertEqual(calls, [1800])

    def test_timeout_kills_extractor_before_releasing_lock(self):
        child_pid_file = self.root / "extractor.pid"
        program = (
            "import pathlib, subprocess, sys, time; "
            "child = subprocess.Popen([sys.executable, '-c', "
            "'import time; time.sleep(60)']); "
            f"pathlib.Path({str(child_pid_file)!r}).write_text(str(child.pid)); "
            "time.sleep(60)"
        )
        killpg = os.killpg
        signals = []

        def stop_while_locked(pgid, sig):
            # Cleanup runs inside the same critical section as the import.
            with (
                open(self.adapter.lock_path) as contender,
                self.assertRaises(BlockingIOError),
            ):
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
            signals.append(sig)
            killpg(pgid, sig)

        with (
            patch("openclaw_music.importer.IMPORT_TIMEOUT", 1),
            patch("openclaw_music.importer.os.killpg", stop_while_locked),
            self.adapter._locked(),
            self.assertRaisesRegex(BackendUncertain, "timed out"),
        ):
            self.adapter._run_unlocked([sys.executable, "-c", program], mutation=True)
        self.assertEqual(signals, [signal.SIGKILL])
        self.assertTrue(child_pid_file.exists())
        child_pid = int(child_pid_file.read_text())
        # Grandchildren are reaped by init; an adopted zombie has stopped and
        # cannot keep extracting or writing after the import lock is released.
        status = Path(f"/proc/{child_pid}/stat")
        deadline = time.monotonic() + 2
        while True:
            try:
                state = status.read_text().rsplit(")", 1)[1].split()[0]
            except FileNotFoundError:
                break
            if state == "Z":
                break
            if time.monotonic() >= deadline:
                os.kill(child_pid, signal.SIGKILL)
                self.fail("extractor survived process-group cleanup")
            time.sleep(0.01)
        with open(self.adapter.lock_path) as contender:
            fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_list_timeout_is_retryable(self):
        with (
            patch("openclaw_music.importer.LIST_TIMEOUT", 0.05),
            self.assertRaisesRegex(BackendTransient, "list timed out"),
        ):
            self.adapter._run_unlocked(
                [sys.executable, "-c", "import time; time.sleep(60)"]
            )

    def test_cancellation_stops_group_and_reaps_beet(self):
        process = unittest.mock.Mock()
        process.pid = 12345
        process.communicate.side_effect = KeyboardInterrupt
        with (
            patch("openclaw_music.importer.subprocess.Popen", return_value=process),
            patch("openclaw_music.importer.os.killpg") as killpg,
            self.assertRaises(KeyboardInterrupt),
        ):
            self.adapter._run_process(["beet", "import"], 1800)
        killpg.assert_called_once_with(12345, signal.SIGKILL)
        process.wait.assert_called_once_with()
        process.stdout.close.assert_called_once_with()
        process.stderr.close.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Black-box subprocess tests for agent-run-long.

The check passes the installed program as argv[1].  Everything executed by
this file is made in a private temporary directory; in particular, there are
no checked-in shell fixtures to accidentally depend on an FHS shell.
"""

from __future__ import annotations

import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("usage: tests.py /path/to/agent-run-long")

RUNNER = os.path.abspath(sys.argv[1])
# Keep unittest from treating the packaged-program argument as a test name.
sys.argv[:] = [sys.argv[0]]


class Result:
    def __init__(self, completed: subprocess.CompletedProcess[bytes], elapsed: float):
        self.code = completed.returncode
        self.out = completed.stdout
        self.elapsed = elapsed
        self.kv = parse_kv(self.out)
        self.log = Path(self.kv["log"]) if "log" in self.kv else None
        if self.log is None:
            # The runner announces this path before starting the command, so it
            # remains recoverable when the wrapper itself is interrupted.
            for line in self.out.decode("utf-8", "surrogateescape").splitlines():
                path = Path(line)
                if path.is_absolute() and path.name == "output.log":
                    self.log = path
                    break
        self.run_dir = self.log.parent if self.log is not None else None
        self.status_file = status_file(self.run_dir)
        self.status = (
            parse_kv(self.status_file.read_bytes()) if self.status_file else {}
        )


def parse_kv(raw: bytes) -> dict[str, str]:
    """Read the runner's documented summary/status fields, not prose."""
    result: dict[str, str] = {}
    fields = {"log", "state", "exit_code", "elapsed_s", "limit_s"}
    for line in raw.decode("utf-8", "surrogateescape").splitlines():
        # Summaries contain space-separated pairs; status has one pair/line.
        for token in line.split():
            key, separator, value = token.partition("=")
            if separator and key in fields:
                result[key] = value
    return result


def status_file(run_dir: Path | None) -> Path | None:
    if run_dir is None:
        return None
    candidate = run_dir / "status"
    return candidate if candidate.is_file() else None


def pid_gone(pid: int, timeout: float = 4.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            remainder = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1]
            if remainder.split(maxsplit=1)[0] == "Z":
                return True
        except (FileNotFoundError, IndexError):
            # /proc may be unavailable (or the process may have just exited);
            # let kill(0) below distinguish that from a live process.
            pass
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.04)
    return False


def wait_for(path: Path, timeout: float = 3.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.02)
    raise AssertionError(f"payload did not publish readiness marker {path}")


class AgentRunLongTests(unittest.TestCase):
    """The CLI contract is --label, --timeout Ns, [--excerpt-lines N], --."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="agent-run-long-test-")
        self.root = Path(self.temp.name)
        # This is intentionally the production fixed base.  We only remove a
        # directory named in this invocation's own summary, never scan or clean
        # other callers' shared /tmp/opencode runs.
        self.base = Path("/tmp/opencode")
        self.fixture = self.root / "fixtures with spaces"
        self.fixture.mkdir()
        self.created: set[Path] = set()

    def tearDown(self) -> None:
        # The runner is allowed to choose names below our per-test base only.
        # Remove no /tmp/opencode path unless it was explicitly emitted to us.
        for run_dir in self.created:
            if run_dir.is_relative_to(self.base):
                shutil.rmtree(run_dir, ignore_errors=True)
        self.temp.cleanup()

    def payload(self, name: str, body: str, *, executable: bool = True) -> Path:
        path = self.fixture / name
        path.write_text(
            "#!" + sys.executable + "\n" + textwrap.dedent(body), encoding="utf-8"
        )
        path.chmod(0o700 if executable else 0o600)
        return path

    def call(
        self,
        command: list[str],
        *,
        label: str = "case",
        timeout: str = "3s",
        no_excerpt: bool = False,
        cwd: Path | None = None,
        outer_timeout: float = 10.0,
        umask: int | None = None,
    ) -> Result:
        args = [RUNNER, "--label", label, "--timeout", timeout]
        if no_excerpt:
            args.extend(["--excerpt-lines", "0"])
        args.extend(["--", *command])
        start = time.monotonic()
        old_umask = os.umask(umask) if umask is not None else None
        try:
            completed = subprocess.run(
                args,
                cwd=cwd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=outer_timeout,
                check=False,
            )
        finally:
            if old_umask is not None:
                os.umask(old_umask)
        result = Result(completed, time.monotonic() - start)
        if result.run_dir:
            self.created.add(result.run_dir)
        return result

    def start(
        self, command: list[str], *, label: str = "signal", timeout: str = "8s"
    ) -> subprocess.Popen[bytes]:
        return subprocess.Popen(
            [RUNNER, "--label", label, "--timeout", timeout, "--", *command],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

    def require_artifacts(self, result: Result) -> tuple[Path, Path]:
        self.assertIsNotNone(result.log, "summary must emit log=<path>")
        self.assertIsNotNone(result.run_dir, "log path must identify a run directory")
        self.assertTrue(result.log.is_file(), "emitted log path must exist")
        self.assertTrue(result.run_dir.is_dir(), "emitted run directory must exist")
        self.assertTrue(
            result.run_dir.is_relative_to(self.base), "run directory escaped log base"
        )
        self.assertIsNotNone(
            result.status_file, "run directory must contain status metadata"
        )
        for field in ("log", "state", "exit_code", "elapsed_s", "limit_s"):
            self.assertIn(field, result.kv, f"summary missing {field}")
            self.assertIn(field, result.status, f"status missing {field}")
            self.assertEqual(
                result.kv[field],
                result.status[field],
                f"summary/status disagree on {field}",
            )
        return result.log, result.run_dir

    def assert_status(self, result: Result, expected: int) -> None:
        self.assertEqual(
            result.code, expected, result.out.decode("utf-8", "backslashreplace")
        )
        actual = result.status.get("exit_code")
        self.assertIsNotNone(actual, "status must include exit_code")
        try:
            self.assertEqual(int(actual), expected)
        except ValueError:
            self.fail(f"non-numeric machine status {actual!r}")

    def marker_pid(self, marker: Path) -> int:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if marker.exists():
                return int(marker.read_text().strip())
            time.sleep(0.02)
        self.fail(f"payload did not publish readiness marker {marker}")

    def assert_gone(self, pid: int, message: str) -> None:
        if pid_gone(pid):
            return
        # A failed containment assertion must not leave its intentionally
        # stubborn fixture alive for the next test or another /tmp/opencode run.
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        pid_gone(pid)
        self.fail(message)

    def interrupt(self, sig: signal.Signals, *, near_start: bool = False) -> Result:
        marker = self.root / f"ready-{sig.name}"
        child = self.root / f"child-{sig.name}"
        work = self.payload(
            "wait.py",
            """
            import os, pathlib, signal, sys, time
            marker, child = map(pathlib.Path, sys.argv[1:])
            signal.signal(signal.SIGTERM, lambda *_: None)
            child.write_text(str(os.getpid()))
            print('partial output', flush=True)
            marker.write_text('ready')
            while True: time.sleep(.05)
        """,
        )
        proc = self.start([os.fspath(work), os.fspath(marker), os.fspath(child)])
        started = time.monotonic()
        out = b""
        try:
            if not near_start:
                wait_for(marker)
            os.kill(proc.pid, sig)
            out, _ = proc.communicate(timeout=10)
        finally:
            if proc.poll() is None:
                proc.kill()
                out, _ = proc.communicate()
        result = Result(
            subprocess.CompletedProcess([], proc.returncode, out, None),
            time.monotonic() - started,
        )
        if result.run_dir:
            self.created.add(result.run_dir)
        if child.exists():
            self.assert_gone(self.marker_pid(child), "interruption leaked worker")
        return result

    def test_success_failure_and_literal_argv(self) -> None:
        argv_file = self.root / "argv.bin"
        program = self.payload(
            "program with spaces.py",
            """
            import pathlib, sys
            pathlib.Path(sys.argv[1]).write_bytes(b'\\0'.join(x.encode() for x in sys.argv[2:]))
            print('OUT-success', flush=True)
            print('ERR-success', file=sys.stderr)
        """,
        )
        args = [
            "",
            "space arg",
            "quote'\\\"arg",
            "$dollar",
            "*glob*",
            "line\\nbreak",
            "-dash",
        ]
        result = self.call(
            [os.fspath(program), os.fspath(argv_file), *args], cwd=self.fixture
        )
        log, _ = self.require_artifacts(result)
        self.assert_status(result, 0)
        self.assertEqual(
            argv_file.read_bytes().split(b"\0"), [x.encode() for x in args]
        )
        self.assertEqual(log.read_bytes(), b"OUT-success\nERR-success\n")
        self.assertEqual(result.status["state"], "exited")

        failure = self.payload(
            "failure.py",
            """
            import sys
            print('distinctive child failure')
            raise SystemExit(47)
        """,
        )
        failed = self.call([os.fspath(failure)], label="failure")
        failed_log, _ = self.require_artifacts(failed)
        self.assert_status(failed, 47)
        self.assertEqual(failed_log.read_bytes(), b"distinctive child failure\n")

    def test_timeout_escalation_and_orphans(self) -> None:
        term = self.root / "term"
        descendant = self.root / "descendant"
        timeout_program = self.payload(
            "timeout.py",
            """
            import pathlib, signal, subprocess, sys, time
            term, descendant = map(pathlib.Path, sys.argv[1:])
            subprocess.Popen([sys.executable, '-c',
                'import os,pathlib,signal,time,sys; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); signal.signal(signal.SIGTERM, lambda *_: pathlib.Path(sys.argv[2]).write_text("TERM")); time.sleep(60)',
                str(descendant), str(term)])
            print('before timeout', flush=True)
            while True: time.sleep(.05)
        """,
        )
        result = self.call(
            [os.fspath(timeout_program), os.fspath(term), os.fspath(descendant)],
            timeout="1s",
        )
        log, _ = self.require_artifacts(result)
        self.assert_status(result, 124)
        self.assertLess(result.elapsed, 8, "timeout cleanup was not bounded")
        self.assertIn(b"before timeout\n", log.read_bytes())
        pid = self.marker_pid(descendant)
        self.assertTrue(term.exists(), "descendant did not receive TERM")
        self.assert_gone(pid, "timeout leaked descendant")

        ignored = self.root / "ignored"
        grandchild = self.root / "grandchild"
        stubborn = self.payload(
            "stubborn.py",
            """
            import os, pathlib, signal, subprocess, sys, time
            parent, grandchild = map(pathlib.Path, sys.argv[1:])
            parent.write_text(str(os.getpid()))
            subprocess.Popen([sys.executable, '-c', 'import os,pathlib,signal,time,sys; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); signal.signal(signal.SIGTERM, lambda *_: None); time.sleep(60)', str(grandchild)])
            signal.signal(signal.SIGTERM, lambda *_: None)
            while True: time.sleep(.05)
        """,
        )
        result = self.call(
            [os.fspath(stubborn), os.fspath(ignored), os.fspath(grandchild)],
            timeout="1s",
            outer_timeout=12,
        )
        self.require_artifacts(result)
        # GNU timeout commonly reports 124 after escalation; do not require 137.
        self.assertIn(result.code, (124, 137))
        self.assertLess(result.elapsed, 10)
        self.assert_gone(
            self.marker_pid(ignored), "escalation leaked TERM-ignoring parent"
        )
        self.assert_gone(
            self.marker_pid(grandchild), "escalation leaked TERM-ignoring grandchild"
        )

    def test_parent_first_exit_and_background_after_normal_exit(self) -> None:
        for name, signal_parent in (
            ("term-parent.py", True),
            ("normal-parent.py", False),
        ):
            child = self.root / (name + ".pid")
            program = self.payload(
                name,
                """
                import pathlib, signal, subprocess, sys, time
                child = pathlib.Path(sys.argv[1])
                subprocess.Popen([sys.executable, '-c', 'import os,pathlib,signal,time,sys; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); signal.signal(signal.SIGTERM, lambda *_: None); time.sleep(60)', str(child)])
                %s
            """
                % (
                    "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); time.sleep(60)"
                    if signal_parent
                    else "time.sleep(.1)"
                ),
            )
            result = self.call(
                [os.fspath(program), os.fspath(child)],
                timeout="1s" if signal_parent else "3s",
                outer_timeout=12,
            )
            self.require_artifacts(result)
            self.assert_gone(self.marker_pid(child), f"{name} leaked background worker")

    def test_concurrency_safety_modes_and_hostile_labels(self) -> None:
        program = self.payload("token.py", "import sys; print(sys.argv[1])")
        procs = [
            subprocess.Popen(
                [
                    RUNNER,
                    "--label",
                    "same-label",
                    "--timeout",
                    "3s",
                    "--",
                    os.fspath(program),
                    str(i),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            for i in range(12)
        ]
        results = []
        for proc in procs:
            out, _ = proc.communicate(timeout=8)
            result = Result(
                subprocess.CompletedProcess([], proc.returncode, out, None), 0
            )
            self.created.add(result.run_dir) if result.run_dir else None
            results.append(result)
        logs = []
        for i, result in enumerate(results):
            log, run_dir = self.require_artifacts(result)
            self.assert_status(result, 0)
            self.assertEqual(log.read_bytes(), f"{i}\n".encode())
            self.assertEqual(stat.S_IMODE(run_dir.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(result.status_file.stat().st_mode), 0o600)
            logs.append(log)
        self.assertEqual(len(set(logs)), len(logs))
        hostile = self.call(
            [os.fspath(program), "ok"], label="../../escape / $bad", umask=0
        )
        _, run_dir = self.require_artifacts(hostile)
        self.assertEqual(stat.S_IMODE(run_dir.stat().st_mode), 0o700)

    def test_setup_errors_do_not_launch_payloads(self) -> None:
        launched = self.root / "launched"
        missing = self.call([os.fspath(self.root / "missing"), os.fspath(launched)])
        self.assertEqual(missing.code, 127)
        self.assertFalse(launched.exists())
        noexec = self.payload("noexec.py", "", executable=False)
        denied = self.call([os.fspath(noexec), os.fspath(launched)])
        self.assertEqual(denied.code, 126)
        self.assertFalse(launched.exists())
        invalid = subprocess.run(
            [RUNNER, "--definitely-invalid"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=5,
            check=False,
        )
        self.assertEqual(invalid.returncode, 2)

    def test_log_base_rejection_is_not_safe_to_mutate_in_a_shared_tmp(self) -> None:
        # The frozen interface deliberately has no log-base override: production
        # always uses /tmp/opencode.  Replacing, chmodding, or symlinking that
        # directory would race unrelated agent runs, so exercise the 125 cases
        # in an isolated integration namespace rather than corrupt this check.
        self.skipTest(
            "/tmp/opencode is shared; unsafe-base mutation is intentionally not isolated"
        )

    def test_large_binary_output_and_excerpt_suppression(self) -> None:
        program = self.payload(
            "large.py",
            """
            import os, sys
            sys.stdout.buffer.write(b'\\x1b[31m' + b'x' * 180000 + b'\\x00END\\n')
            sys.stdout.flush()
        """,
        )
        result = self.call([os.fspath(program)])
        log, _ = self.require_artifacts(result)
        self.assert_status(result, 0)
        expected = b"\x1b[31m" + b"x" * 180000 + b"\x00END\n"
        self.assertEqual(log.read_bytes(), expected)
        self.assertLess(len(result.out), 12000, "rendered excerpt was not bounded")
        self.assertNotIn(b"\x00", result.out)
        self.assertNotIn(b"\x1b", result.out)

        suppressed = self.call([os.fspath(program)], no_excerpt=True)
        suppressed_log, _ = self.require_artifacts(suppressed)
        self.assert_status(suppressed, 0)
        self.assertEqual(suppressed_log.read_bytes(), expected)
        self.assertLess(len(suppressed.out), 2048, "suppressed excerpt was not bounded")
        self.assertNotIn(b"--- last ", suppressed.out)

    def test_signal_interruption(self) -> None:
        for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            result = self.interrupt(sig)
            self.assert_status(result, 128 + sig)
            self.assertLess(result.elapsed, 10, "signal cleanup was not bounded")
            log, _ = self.require_artifacts(result)
            self.assertIn(
                b"partial output\n",
                log.read_bytes(),
                "interruption lost partial output",
            )

    def test_near_start_signal_does_not_report_success(self) -> None:
        result = self.interrupt(signal.SIGTERM, near_start=True)
        self.assertIn(result.code, (-signal.SIGTERM, 143))
        self.assertNotEqual(result.code, 0)
        if result.log is not None:
            self.assertTrue(result.log.is_file(), "announced log path must exist")
            if result.status_file is not None:
                self.assertNotEqual(result.status.get("exit_code"), "0")

    def test_hard_wrapper_kill_preserves_log(self) -> None:
        marker = self.root / "hard-kill"
        program = self.payload(
            "hard.py",
            """
            import os, pathlib, sys, time
            pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
            print('bytes before hard kill', flush=True)
            time.sleep(60)
        """,
        )
        proc = self.start([os.fspath(program), os.fspath(marker)], timeout="8s")
        wait_for(marker)
        worker = self.marker_pid(marker)
        try:
            os.kill(proc.pid, signal.SIGKILL)
            out, _ = proc.communicate(timeout=5)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()
            try:
                os.kill(worker, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.assertTrue(pid_gone(worker), "hard-kill cleanup left worker behind")
        result = Result(subprocess.CompletedProcess([], proc.returncode, out, None), 0)
        self.assertEqual(result.code, -signal.SIGKILL)
        self.assertIsNotNone(result.log, "early summary must expose the log path")
        self.assertIn(b"bytes before hard kill\n", result.log.read_bytes())
        self.assertNotEqual(result.status.get("exit_code"), "0")


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""Hermetic tests of the inline writeShellApplication launcher bodies.

Run with Python 3; requires bash, coreutils, findutils, jq and flock.
Only Nix path substitutions and the clock/beet/timeout/flock tools are replaced.
All fixture data stays in a temporary directory. An optional source-file
argument also allows running the tests against immutable Nix store sources.
"""

import fcntl
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import contextmanager
from pathlib import Path

SOURCE = (
    Path(sys.argv.pop(1))
    if len(sys.argv) > 1
    else Path(__file__).resolve().parents[1] / "beets.nix"
).read_text()


def shell_body(binding):
    block = SOURCE.split(f"      {binding} = pkgs.writeShellApplication {{", 1)[1]
    body = block.split("        text = ''\n", 1)[1].split("\n        '';", 1)[0]
    return body.replace("''${", "${")


FAKE_BEET = r"""
import json, os, signal, sys, time
from pathlib import Path
args = sys.argv[1:]
cfg = json.loads(Path(args[args.index('-c') + 1]).read_text())
assert args[args.index('-p') + 1] == 'xtractor'
assert cfg['xtractor']['write'] is False
assert cfg['xtractor']['force'] is False
assert os.environ['BEETSDIR'] == os.environ['FIXTURE_BEETSDIR']
counting = '--count-only' in args
call = {'op': 'count' if counting else 'analysis', 'args': args, 'config': cfg}
with open(os.environ['FIXTURE_CALLS'], 'a') as calls:
    calls.write(json.dumps(call) + '\n')
if counting:
    if os.environ.get('COUNT_MODE') == 'wait':
        while not Path(os.environ['FIXTURE_RELEASE']).exists():
            time.sleep(0.01)
    if os.environ.get('COUNT_EXIT'):
        sys.stderr.write('count failed\n')
        sys.exit(int(os.environ['COUNT_EXIT']))
    sys.stderr.write(os.environ.get('COUNT_MESSAGE',
        'xtractor: Number of items to be processed: ' + os.environ['ITEM_COUNT']) + '\n')
    sys.exit(0)
assert args[-3:] == ['xt', '-t', '14']
assert os.environ['OMP_NUM_THREADS'] == '1'
assert os.environ['OPENBLAS_NUM_THREADS'] == '1'
output = Path(cfg['xtractor']['output_path'])
assert output.is_dir()
assert output.parent == Path(os.environ['FIXTURE_OUTPUT'])
assert not list(output.glob('*.json')) or list(output.glob('*.json')) == [output / 'config.json']
(output / 'partial.json').write_text('{unfinished')
mode = os.environ.get('ANALYSIS_MODE', 'finish')
if mode != 'finish':
    (output / 'pid').write_text(str(os.getpid()))
    if mode == 'stubborn':
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    while not Path(os.environ['FIXTURE_RELEASE']).exists():
        time.sleep(0.01)
sys.exit(int(os.environ.get('ANALYSIS_EXIT', '0')))
"""


class BackfillTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="beets-backfill-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.beets = self.root / "beets"
        self.beets.mkdir()
        self.output = self.beets / "xtractor"
        self.calls = self.root / "calls"
        self.flock_calls = self.root / "flock-calls"
        self.timeout_calls = self.root / "timeout-calls"
        self.release = self.root / "release"
        self.env = dict(
            os.environ,
            PATH=f"{self.bin}:{os.environ['PATH']}",
            PYTHONDONTWRITEBYTECODE="1",
            FIXTURE_BEETSDIR=str(self.beets),
            FIXTURE_OUTPUT=str(self.output),
            FIXTURE_CALLS=str(self.calls),
            FIXTURE_FLOCK_CALLS=str(self.flock_calls),
            FIXTURE_TIMEOUT_CALLS=str(self.timeout_calls),
            FIXTURE_RELEASE=str(self.release),
            ITEM_COUNT="2",
            CLOCK_NOW="100",
            CLOCK_START="90",
            CLOCK_STOP="10000",
        )
        self.executable("beet", FAKE_BEET)
        self.real_date = shutil.which("date")
        self.executable(
            "date",
            f"""
import os, sys
key = 'CLOCK_NOW' if sys.argv[1:] == ['+%s'] else (
    'CLOCK_START' if '01:00:00' in sys.argv[1] else 'CLOCK_STOP')
if key != 'CLOCK_NOW' and os.environ.get('CLOCK_DAY'):
    args = [arg.replace('today', os.environ['CLOCK_DAY']) for arg in sys.argv[1:]]
    os.execv({self.real_date!r}, ['date', *args])
print(os.environ[key])
""",
        )
        self.executable(
            "flock",
            f"""
import json, os, sys
args = sys.argv[1:]
with open(os.environ['FIXTURE_FLOCK_CALLS'], 'a') as calls:
    calls.write(json.dumps(args) + '\\n')
assert args[args.index('--timeout') + 1] == '300'
args[args.index('--timeout') + 1] = '0.15'
os.execv({shutil.which("flock")!r}, ['flock', *args])
""",
        )
        self.executable(
            "timeout",
            f"""
import json, os, sys
args = sys.argv[1:]
with open(os.environ['FIXTURE_TIMEOUT_CALLS'], 'a') as calls:
    calls.write(json.dumps(args) + '\\n')
assert args[:2] == ['--signal=TERM', '--kill-after=60s']
# Only accelerate escalation; the production clock calculation stays intact.
args[1] = '--kill-after=0.2s'
os.execv({shutil.which("timeout")!r}, ['timeout', *args])
""",
        )
        count_config = self.root / "count.json"
        count_config.write_text(
            json.dumps({"xtractor": {"write": False, "force": False}})
        )
        worker = shell_body("backfill-run")
        for old, new in {
            "${lib.escapeShellArg beets-dir}": shlex.quote(str(self.beets)),
            "${lib.escapeShellArg (lib.getExe beets-plugins)}": shlex.quote(
                str(self.bin / "beet")
            ),
            "${lib.escapeShellArg xtractor-output}": shlex.quote(str(self.output)),
            "${backfill-count-config}": shlex.quote(str(count_config)),
            "${toString backfill-workers}": "14",
        }.items():
            worker = worker.replace(old, new)
        self.worker = self.shell("worker", worker)
        launcher = shell_body("beets-xtractor-backfill").replace(
            "${lib.getExe backfill-run}", shlex.quote(str(self.worker))
        )
        self.launcher = self.shell("launcher", launcher)

    def executable(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + body)
        path.chmod(0o700)
        return path

    def shell(self, name, body):
        self.assertNotIn("${lib.", body)
        path = self.bin / name
        path.write_text(f"#!{shutil.which('bash')}\nset -euo pipefail\n" + body)
        path.chmod(0o700)
        return path

    def run_launcher(self, mode=None, **env):
        return subprocess.run(
            [str(self.launcher)] + ([] if mode is None else [mode]),
            env=self.env | env,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )

    def recorded(self):
        return (
            [json.loads(line) for line in self.calls.read_text().splitlines()]
            if self.calls.exists()
            else []
        )

    @contextmanager
    def hold_lock(self):
        with open(self.beets / ".import.lock", "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield handle

    def start_analysis(self, **env):
        proc = subprocess.Popen(
            [str(self.launcher)],
            env=self.env | env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.stop_process, proc)
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if any(call["op"] == "analysis" for call in self.recorded()):
                return proc
            if proc.poll() is not None:
                self.fail(f"Launcher exited before analysis: {proc.communicate()}")
            time.sleep(0.01)
        self.fail("Analysis did not start")

    def stop_process(self, proc):
        self.release.touch()
        proc.communicate(timeout=4)

    def test_outside_window_never_invokes_beet_or_opens_lock(self):
        for now in ("89", "10000", "10001"):
            with self.subTest(now=now):
                result = self.run_launcher(CLOCK_NOW=now)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.recorded(), [])
                self.assertFalse((self.beets / ".import.lock").exists())

    def test_manual_runs_outside_window_with_elapsed_budget(self):
        for now in ("89", "10000", "10001"):
            with self.subTest(now=now):
                result = self.run_launcher(mode="now", CLOCK_NOW=now)
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads(self.timeout_calls.read_text().splitlines()[-1])
                self.assertEqual(args[2], "28740s")
        self.assertEqual(
            [call["op"] for call in self.recorded()], ["count", "analysis"] * 3
        )
        self.assertEqual(len(self.flock_calls.read_text().splitlines()), 3)
        self.assertFalse(list(self.output.glob("backfill-*")))

    def test_unknown_mode_fails_without_work(self):
        self.assertEqual(self.run_launcher(mode="invalid").returncode, 2)
        self.assertEqual(self.recorded(), [])
        self.assertFalse((self.beets / ".import.lock").exists())

    def test_zero_items_does_not_wait_for_lock_or_create_output(self):
        result = self.run_launcher(ITEM_COUNT="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.beets / ".import.lock").exists())
        self.assertFalse(self.flock_calls.exists())
        with self.hold_lock():
            result = self.run_launcher(ITEM_COUNT="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call["op"] for call in self.recorded()], ["count", "count"])
        self.assertFalse(self.flock_calls.exists())
        self.assertFalse(self.output.exists())

    def test_deadline_bounds_count_before_lock(self):
        result = self.run_launcher(COUNT_MODE="wait", CLOCK_STOP="101")
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertEqual([call["op"] for call in self.recorded()], ["count"])
        self.assertFalse((self.beets / ".import.lock").exists())
        self.assertFalse(self.flock_calls.exists())
        self.assertFalse(self.output.exists())

    def test_deadline_uses_local_wall_time_across_dst_changes(self):
        for day, budget in (
            ("2026-03-08", 6 * 3600 + 59 * 60),
            ("2026-11-01", 8 * 3600 - 60),
        ):
            with self.subTest(day=day):
                now = subprocess.check_output(
                    [self.real_date, f"--date={day} 01:00:00", "+%s"],
                    env=self.env | {"TZ": "America/New_York"},
                    text=True,
                ).strip()
                result = self.run_launcher(
                    ITEM_COUNT="0", CLOCK_DAY=day, CLOCK_NOW=now, TZ="America/New_York"
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                args = json.loads(self.timeout_calls.read_text().splitlines()[-1])
                self.assertEqual(args[2], f"{budget}s")

    def test_failed_and_unrecognized_counts_fail_without_lock(self):
        for env in (
            {"COUNT_EXIT": "7"},
            {"COUNT_MESSAGE": "wrong output"},
            {
                "COUNT_MESSAGE": "Number of items to be processed: 2\nNumber of items to be processed: 3"
            },
        ):
            with self.subTest(env=env):
                result = self.run_launcher(**env)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.beets / ".import.lock").exists())
                self.assertFalse(self.output.exists())

    def test_busy_lock_skips_successfully_without_cleanup(self):
        self.output.mkdir()
        stale = self.output / "backfill-stale"
        stale.mkdir()
        with self.hold_lock():
            result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("lock busy", result.stdout)
        self.assertTrue(stale.exists())
        self.assertEqual([call["op"] for call in self.recorded()], ["count"])

    def test_waiting_launcher_acquires_released_lock(self):
        with self.hold_lock() as handle:
            proc = subprocess.Popen(
                [str(self.launcher)],
                env=self.env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.addCleanup(self.stop_process, proc)
            deadline = time.monotonic() + 2
            while not self.recorded() and time.monotonic() < deadline:
                time.sleep(0.01)
            fcntl.flock(handle, fcntl.LOCK_UN)
            _, stderr = proc.communicate(timeout=3)
        self.assertEqual(proc.returncode, 0, stderr)
        self.assertEqual(
            [call["op"] for call in self.recorded()], ["count", "analysis"]
        )

    def test_fresh_output_cleanup_and_stale_reclamation(self):
        self.output.mkdir()
        stale = self.output / "backfill-abandoned"
        stale.mkdir()
        (stale / "partial.json").write_text("{unfinished")
        unrelated = self.output / "unrelated"
        unrelated.mkdir()
        (unrelated / "keep").write_text("keep")
        (self.output / "backfill-symlink").symlink_to(
            unrelated, target_is_directory=True
        )
        paths = []
        for _ in range(2):
            result = self.run_launcher()
            self.assertEqual(result.returncode, 0, result.stderr)
            paths.append(self.recorded()[-1]["config"]["xtractor"]["output_path"])
            self.assertFalse(Path(paths[-1]).exists())
        self.assertNotEqual(paths[0], paths[1])
        self.assertFalse(stale.exists())
        self.assertTrue((self.output / "backfill-symlink").is_symlink())
        self.assertEqual((unrelated / "keep").read_text(), "keep")

    def test_lock_remains_held_through_analysis(self):
        proc = self.start_analysis(ANALYSIS_MODE="wait")
        with (
            open(self.beets / ".import.lock", "a") as contender,
            self.assertRaises(BlockingIOError),
        ):
            fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.release.touch()
        _, stderr = proc.communicate(timeout=3)
        self.assertEqual(proc.returncode, 0, stderr)
        with self.hold_lock():
            pass

    def test_failed_analysis_cleans_output_and_releases_lock(self):
        result = self.run_launcher(ANALYSIS_EXIT="9")
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertFalse(list(self.output.glob("backfill-*")))
        with self.hold_lock():
            pass

    def test_deadline_terminates_stock_command_and_cleans_output(self):
        result = self.run_launcher(ANALYSIS_MODE="wait", CLOCK_STOP="101")
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertFalse(list(self.output.glob("backfill-*")))
        with self.hold_lock():
            pass

    def test_forced_kill_leaves_only_disposable_output(self):
        result = self.run_launcher(ANALYSIS_MODE="stubborn", CLOCK_STOP="101")
        self.assertEqual(result.returncode, -9, result.stderr)
        abandoned = list(self.output.glob("backfill-*"))
        self.assertEqual(len(abandoned), 1)
        # Subsequent work must neither reuse nor parse the partial JSON.
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(list(self.output.glob("backfill-*")))
        with self.hold_lock():
            pass


if __name__ == "__main__":
    unittest.main(verbosity=2)

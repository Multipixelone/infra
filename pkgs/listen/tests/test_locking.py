"""Lock contention uses only throwaway libraries; Plex is always mocked."""

import fcntl
import json
import os
import sqlite3
import subprocess
import sys
import time
import unittest
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from io import StringIO
from unittest.mock import patch

import yaml
from listen_queue.cli import access_mode, main, parser
from listen_queue.errors import ListenError
from listen_queue.library import Queue, retry_busy
from test_cli import LibraryCase
from test_plex import container, plex_album, plex_server


@contextmanager
def held_lock(path):
    with open(path, "a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield handle


class LockingTests(LibraryCase):
    def setUp(self):
        super().setUp()
        self.env.update(
            LISTEN_BEETS_LOCK_TIMEOUT="0.15",
            LISTEN_SQLITE_BUSY_TIMEOUT="0.2",
            LISTEN_PLEX_SOURCE="listen list:)",
            LISTEN_PLEX_DONE_SOURCE="albums im rocking w",
        )

    def mocked_invoke(self, *args, exit_code=0):
        output = StringIO()
        server = plex_server([container("playlist", [plex_album()])])
        with (
            patch.dict(os.environ, self.env),
            patch("listen_queue.plex.connect", return_value=server),
            redirect_stdout(output),
        ):
            self.assertEqual(main([*map(str, args), "--json"]), exit_code)
        result = json.loads(output.getvalue())
        self.assertEqual(result["ok"], exit_code == 0)
        return result["data" if exit_code == 0 else "error"]

    def child(self, *args):
        process = subprocess.Popen(
            [sys.executable, "-m", "listen_queue.cli", *map(str, args), "--json"],
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        def cleanup():
            if process.poll() is None:
                process.kill()
                process.communicate()

        self.addCleanup(cleanup)
        return process

    def test_reads_succeed_with_import_and_state_locks_held(self):
        self.create({"album": "One", "state": "queued"})
        state = self.root / "state"
        state.mkdir(mode=0o700)
        before = (self.root / "library.db").read_bytes()
        with held_lock(self.root / ".import.lock"), held_lock(state / ".lock"):
            for args in (
                ("pick", "--max-minutes", 45),
                ("pick", "--pool", "--artist", "Nobody", "--max-minutes", 45),
                ("list",),
                ("list", "--state", "all"),
                ("moods",),
                ("most-played",),
                ("most-played", "--listened-only"),
            ):
                with self.subTest(args=args):
                    self.invoke(*args)
            for command in ("seed-plex", "sync-plex"):
                self.assertFalse(self.mocked_invoke(command)["applied"])
        self.assertEqual((self.root / "library.db").read_bytes(), before)
        self.assertEqual({p.name for p in state.iterdir()}, {".lock"})

    def test_reads_never_open_either_lock_or_create_state(self):
        self.create({"album": "One", "state": "queued"})
        # A nonexistent parent catches even opening/creating the import lock.
        self.env["LISTEN_BEETS_LOCK"] = str(self.root / "missing/lock")
        before = (self.root / "library.db").read_bytes()
        for args in (
            ("pick", "--max-minutes", 45),
            ("list",),
            ("moods",),
            ("most-played",),
            ("seed-plex",),
            ("sync-plex",),
        ):
            with (
                self.subTest(args=args),
                patch("listen_queue.cli.shared_lock", side_effect=AssertionError),
                patch("listen_queue.cli.state_lock", side_effect=AssertionError),
            ):
                self.mocked_invoke(*args)
        self.assertEqual((self.root / "library.db").read_bytes(), before)
        self.assertFalse((self.root / "state").exists())
        self.assertFalse((self.root / ".import.lock").exists())

    def test_all_beets_writers_time_out_then_succeed(self):
        (album_id,) = self.create({"album": "One", "state": "queued"})
        before = (self.root / "library.db").read_bytes()
        commands = (
            ("add", "--id", album_id),
            ("done", "--id", album_id),
            ("drop", "--id", album_id),
            ("done",),
            ("drop",),
            ("seed-plex", "--apply"),
            ("sync-plex", "--apply"),
        )
        with held_lock(self.root / ".import.lock"):
            for args in commands:
                with self.subTest(args=args):
                    start = time.monotonic()
                    error = self.mocked_invoke(*args, exit_code=75)
                    self.assertEqual(error["code"], "backend_unavailable")
                    self.assertIn("import/backfill running", error["message"])
                    self.assertLess(time.monotonic() - start, 2)
                    self.assertEqual((self.root / "library.db").read_bytes(), before)
                    self.assertFalse((self.root / "state").exists())
        for args in commands[:3]:
            self.invoke(*args)
        self.invoke("add", "--id", album_id)
        for command in ("done", "drop"):
            self.invoke("pick", "--choose", album_id)
            self.invoke(command)
            self.invoke("add", "--id", album_id)
        self.mocked_invoke("seed-plex", "--apply")
        self.mocked_invoke("sync-plex", "--apply")

    def test_human_import_busy_error_and_zero_timeout(self):
        (album_id,) = self.create({"album": "One"})
        self.env["LISTEN_BEETS_LOCK_TIMEOUT"] = "0"
        with held_lock(self.root / ".import.lock"):
            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "listen_queue.cli",
                    "add",
                    "--id",
                    str(album_id),
                ],
                env=self.env,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        self.assertEqual(result.returncode, 75)
        self.assertEqual(result.stdout, "")
        self.assertIn("Beets is busy (import/backfill running)", result.stderr)

    def test_choice_uses_only_state_lock_and_preserves_database(self):
        (album_id,) = self.create({"album": "One", "state": "queued"})
        before = (self.root / "library.db").read_bytes()
        with held_lock(self.root / ".import.lock"):
            self.invoke("pick", "--choose", album_id)
        self.assertEqual((self.root / "library.db").read_bytes(), before)
        receipt = (self.root / "state/last-pick.json").read_bytes()
        with held_lock(self.root / "state/.lock"):
            start = time.monotonic()
            error = self.invoke("pick", "--choose", album_id, exit_code=75)
            self.assertIn("Listen state is busy", error["message"])
            self.assertLess(time.monotonic() - start, 8)
            self.assertEqual((self.root / "state/last-pick.json").read_bytes(), receipt)

    def test_state_writers_wait_until_private_lock_released(self):
        (album_id,) = self.create({"album": "One", "state": "queued"})
        self.invoke("pick", "--choose", album_id)
        for args in (("pick", "--choose", album_id), ("done",), ("drop",)):
            self.invoke("add", "--id", album_id)
            self.invoke("pick", "--choose", album_id)
            with held_lock(self.root / "state/.lock") as handle:
                process = self.child(*args)
                time.sleep(0.3)
                self.assertIsNone(process.poll())
                fcntl.flock(handle, fcntl.LOCK_UN)
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr + stdout)
                self.assertTrue(json.loads(stdout)["ok"])
        # Seed shares the state lock with choices and receipt consumption.
        self.env["LISTEN_SQLITE_BUSY_TIMEOUT"] = "0"
        stderr = StringIO()
        with held_lock(self.root / "state/.lock"), redirect_stderr(stderr):
            error = self.mocked_invoke("seed-plex", "--apply", exit_code=75)
        self.assertIn("Listen state is busy", error["message"])
        self.assertFalse((self.root / "state/plex-seed.json").exists())

    def test_persistent_sqlite_busy_is_bounded_and_does_not_save_choice(self):
        (album_id,) = self.create({"album": "One", "state": "queued"})
        # The beets timeout must not override our bounded read retry budget.
        config = yaml.safe_load(self.config.read_text())
        config["timeout"] = 120
        self.config.write_text(yaml.safe_dump(config))
        connection = sqlite3.connect(self.root / "library.db")
        self.addCleanup(connection.close)
        connection.execute("BEGIN EXCLUSIVE")
        for args in (("list",), ("pick", "--choose", album_id)):
            start = time.monotonic()
            error = self.invoke(*args, exit_code=75)
            self.assertEqual(error["code"], "backend_unavailable")
            self.assertIn("database is busy", error["message"])
            self.assertGreaterEqual(time.monotonic() - start, 0.2)
            self.assertLess(time.monotonic() - start, 3)
        self.assertFalse((self.root / "state/last-pick.json").exists())
        connection.rollback()
        self.invoke("list")

    def test_sqlite_read_recovers_after_exclusive_transaction_released(self):
        self.create({"album": "One", "state": "queued"})
        self.env["LISTEN_SQLITE_BUSY_TIMEOUT"] = "3"
        connection = sqlite3.connect(self.root / "library.db")
        self.addCleanup(connection.close)
        connection.execute("BEGIN EXCLUSIVE")
        process = self.child("list")
        time.sleep(0.5)
        self.assertIsNone(process.poll())
        connection.rollback()
        stdout, stderr = process.communicate(timeout=5)
        self.assertEqual(process.returncode, 0, stderr + stdout)
        self.assertEqual(json.loads(stdout)["data"]["albums"][0]["album"], "One")

    def test_reads_see_wal_changes_without_migrating_or_writing(self):
        (album_id,) = self.create({"album": "One", "state": "queued"})
        connection = sqlite3.connect(self.root / "library.db")
        self.addCleanup(connection.close)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.execute(
            "UPDATE albums SET album = 'Changed' WHERE id = ?", (album_id,)
        )
        connection.commit()
        connection.execute("BEGIN IMMEDIATE")
        self.assertEqual(self.invoke("list")["albums"][0]["album"], "Changed")
        connection.rollback()
        connection.execute("DROP TABLE migrations")
        connection.commit()
        before = (self.root / "library.db-wal").read_bytes()
        self.assertEqual(self.invoke("list")["albums"][0]["album"], "Changed")
        self.assertEqual((self.root / "library.db-wal").read_bytes(), before)
        self.assertIsNone(
            connection.execute(
                "SELECT name FROM sqlite_master WHERE name='migrations'"
            ).fetchone()
        )

    def test_read_only_adapter_rejects_sql_writes_and_handles_uri_characters(self):
        self.create({"album": "One", "state": "queued"})
        path = self.root / "library ?#.db"
        (self.root / "library.db").rename(path)
        config = yaml.safe_load(self.config.read_text())
        config["library"] = str(path)
        self.config.write_text(yaml.safe_dump(config))
        queue = Queue(self.config, self.root / "state", read_only=True)
        self.addCleanup(queue.close)
        self.assertEqual(queue.metadata(queue.albums()[0])["album"], "One")
        with self.assertRaises(sqlite3.OperationalError):
            queue.lib._connection().execute("UPDATE albums SET album='Forbidden'")
        self.assertEqual(self.invoke("list")["albums"][0]["album"], "One")

    def test_late_metadata_busy_retries_before_single_receipt_write(self):
        (album_id,) = self.create({"album": "One", "state": "queued"})
        metadata = Queue.metadata
        calls = []

        def flaky_metadata(queue, album):
            calls.append(album.id)
            self.assertFalse((self.root / "state/last-pick.json").exists())
            if len(calls) == 1:
                raise sqlite3.OperationalError("database is locked")
            return metadata(queue, album)

        with patch.object(Queue, "metadata", flaky_metadata):
            self.mocked_invoke("pick", "--choose", album_id)
        self.assertEqual(calls, [album_id, album_id])
        self.assertEqual(
            json.loads((self.root / "state/last-pick.json").read_text())["album_id"],
            album_id,
        )

    def test_invalid_timeouts_fail_before_creating_locks(self):
        self.create({"album": "One"})
        for variable in ("LISTEN_BEETS_LOCK_TIMEOUT", "LISTEN_SQLITE_BUSY_TIMEOUT"):
            for value in ("-1", "nan", "inf", "bad"):
                with self.subTest(variable=variable, value=value):
                    self.env[variable] = value
                    error = self.invoke("list", exit_code=78)
                    self.assertEqual(error["code"], "configuration_invalid")
                    self.assertIn(variable, error["message"])
            self.env[variable] = "0.2"
        self.assertFalse((self.root / ".import.lock").exists())
        self.assertFalse((self.root / "state").exists())


class RetryTests(unittest.TestCase):
    def test_backoff_recovers_and_unrelated_errors_are_not_retried(self):
        operation = unittest.mock.Mock(
            side_effect=[
                sqlite3.OperationalError("database is locked"),
                sqlite3.OperationalError("database is busy"),
                "result",
            ]
        )
        with patch("listen_queue.library.time.sleep") as sleep:
            self.assertEqual(retry_busy(operation, 1), "result")
        self.assertEqual([call.args[0] for call in sleep.call_args_list], [0.05, 0.1])
        for error in (
            sqlite3.OperationalError("no such table"),
            sqlite3.DatabaseError("corrupt"),
        ):
            operation = unittest.mock.Mock(side_effect=error)
            with self.assertRaises(type(error)):
                retry_busy(operation, 1)
            operation.assert_called_once()

    def test_extended_busy_code_and_deadline_stop_retries(self):
        error = sqlite3.OperationalError("private sqlite diagnostics")
        error.sqlite_errorcode = sqlite3.SQLITE_BUSY | (2 << 8)
        operation = unittest.mock.Mock(side_effect=error)
        with self.assertRaises(ListenError) as failure:
            retry_busy(operation, 0)
        self.assertEqual(failure.exception.exit_code, 75)
        self.assertNotIn("private", failure.exception.message)
        operation.assert_called_once()

    def test_all_command_modes(self):
        expected = {
            ("pick",): (False, False),
            ("list",): (False, False),
            ("moods",): (False, False),
            ("most-played",): (False, False),
            ("seed-plex",): (False, False),
            ("sync-plex",): (False, False),
            ("pick", "--choose", "1"): (False, True),
            ("add", "--id", "1"): (True, False),
            ("done",): (True, True),
            ("drop",): (True, True),
            ("seed-plex", "--apply"): (True, True),
            ("sync-plex", "--apply"): (True, False),
        }
        for args, mode in expected.items():
            with self.subTest(args=args):
                self.assertEqual(access_mode(parser().parse_args(args)), mode)

"""Real SQLite inputs, including WAL on entirely unwritable source paths."""

import errno
import importlib.util
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import closing, contextmanager
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location("snapshot", SOURCE)
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.database = self.source / "library.db"
        self.target = self.root / "copy.db"

    def writer(self, wal=True):
        connection = sqlite3.connect(self.database, check_same_thread=False)
        if wal:
            connection.execute("PRAGMA journal_mode=WAL")
        connection.execute("CREATE TABLE fixture(value)")
        connection.execute("INSERT INTO fixture VALUES (1)")
        connection.commit()
        return connection

    @contextmanager
    def readonly(self):
        paths = list(self.source.iterdir())
        for path in paths:
            path.chmod(0o400)
        self.source.chmod(0o500)
        try:
            # This fixture must actually deny writes, including on CI.
            self.assertFalse(os.access(self.source, os.W_OK))
            for path in paths:
                self.assertFalse(os.access(path, os.W_OK))
            yield
        finally:
            self.source.chmod(0o700)
            for path in paths:
                if path.exists():
                    path.chmod(0o600)

    def copy(self, seconds=5):
        snapshot.snapshot(self.database, self.target, time.monotonic() + seconds)

    def value(self):
        with closing(sqlite3.connect(self.target)) as connection:
            self.assertEqual(
                connection.execute("PRAGMA integrity_check").fetchone()[0], "ok"
            )
            return connection.execute("SELECT value FROM fixture").fetchone()[0]

    def test_readonly_wal_with_active_writer_and_unwritable_sidecars(self):
        writer = self.writer()
        try:
            writer.execute("UPDATE fixture SET value=2")
            writer.commit()
            writer.execute("UPDATE fixture SET value=3")
            with (
                self.readonly(),
                patch.object(snapshot, "read_lease", side_effect=AssertionError),
            ):
                self.copy()
                self.assertEqual(self.value(), 2)
                self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)
            writer.commit()
            self.assertEqual(self.value(), 2)
        finally:
            writer.close()

    def test_readonly_wal_without_sidecars_uses_protected_fallback(self):
        self.writer().close()
        self.assertEqual(set(self.source.iterdir()), {self.database})
        # Both header versions stay WAL even after clean shutdown.
        self.assertEqual(self.database.read_bytes()[18:20], b"\x02\x02")
        original = self.database.read_bytes()
        with self.readonly():
            with self.assertRaises(sqlite3.OperationalError) as failure:
                snapshot.backup(self.database, self.target, time.monotonic() + 5)
            self.assertEqual(
                failure.exception.sqlite_errorcode, sqlite3.SQLITE_READONLY_DIRECTORY
            )
            self.copy()
            self.assertEqual(self.value(), 1)
            self.assertEqual(set(self.source.iterdir()), {self.database})
        self.assertEqual(self.database.read_bytes(), original)

    def test_readonly_rollback_database_needs_no_lease_or_sidecars(self):
        self.writer(wal=False).close()
        with (
            self.readonly(),
            patch.object(snapshot, "read_lease", side_effect=AssertionError),
        ):
            self.copy()
            self.assertEqual(self.value(), 1)
            self.assertEqual(set(self.source.iterdir()), {self.database})

    def test_fallback_preserves_committed_wal_after_unclean_writer_exit(self):
        subprocess.run(
            [
                sys.executable,
                "-c",
                (
                    "import os,sqlite3,sys; c=sqlite3.connect(sys.argv[1]); "
                    "c.execute('PRAGMA journal_mode=WAL'); "
                    "c.execute('CREATE TABLE fixture(value)'); "
                    "c.execute('INSERT INTO fixture VALUES(7)'); "
                    "c.commit(); os._exit(0)"
                ),
                str(self.database),
            ],
            check=True,
        )
        wal = Path(str(self.database) + "-wal")
        self.assertGreater(wal.stat().st_size, 0)
        Path(str(self.database) + "-shm").unlink()
        original = {path: path.read_bytes() for path in self.source.iterdir()}
        with self.readonly():
            self.copy()
            self.assertEqual(self.value(), 7)
            # Resolve aliases before copying sidecars, as SQLite itself does.
            alias = self.root / "alias.db"
            alias.symlink_to(self.database)
            snapshot.snapshot(alias, self.target, time.monotonic() + 5)
            self.assertEqual(self.value(), 7)
        self.assertEqual(
            {path: path.read_bytes() for path in self.source.iterdir()}, original
        )

    def test_read_lease_refuses_an_existing_writer(self):
        writer = self.writer()
        try:
            with (
                self.assertRaises(OSError) as failure,
                snapshot.read_lease(self.database),
            ):
                self.fail("Lease admitted a live writer")
            self.assertEqual(failure.exception.errno, errno.EAGAIN)
        finally:
            writer.close()

    def test_read_lease_yields_promptly_to_a_new_writer(self):
        self.writer().close()
        child = None
        try:
            with snapshot.read_lease(self.database) as check:
                child = subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        (
                            "import sqlite3,sys; "
                            "c=sqlite3.connect(sys.argv[1]); "
                            "c.execute('UPDATE fixture SET value=2'); c.commit()"
                        ),
                        str(self.database),
                    ],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                deadline = time.monotonic() + 2
                while time.monotonic() < deadline:
                    try:
                        check()
                    except snapshot.LeaseBroken:
                        break
                    time.sleep(0.01)
                else:
                    self.fail("Snapshot did not notice the writer's lease break")
                self.assertIsNone(child.poll())
                # Context cleanup releases the lease even during an abort.
                with self.assertRaises(snapshot.LeaseBroken):
                    check()
                # The context's final check must also reject publication.
                raise snapshot.LeaseBroken()
        except snapshot.LeaseBroken:
            pass
        finally:
            if child is not None:
                try:
                    _, stderr = child.communicate(timeout=2)
                    self.assertEqual(child.returncode, 0, stderr)
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate()

    def test_concurrent_commits_produce_an_internally_consistent_snapshot(self):
        writer = self.writer()
        writer.execute("INSERT INTO fixture VALUES (1)")
        writer.commit()
        stop = threading.Event()
        errors = []

        def update():
            try:
                for value in range(2, 200):
                    if stop.is_set():
                        break
                    writer.execute("UPDATE fixture SET value=?", (value,))
                    writer.commit()
            except sqlite3.Error as exc:
                errors.append(exc)

        thread = threading.Thread(target=update)
        try:
            with self.readonly():
                thread.start()
                self.copy()
                with closing(sqlite3.connect(self.target)) as reader:
                    values = reader.execute("SELECT value FROM fixture").fetchall()
                    self.assertEqual(len(values), 2)
                    self.assertEqual(values[0], values[1])
        finally:
            stop.set()
            thread.join(5)
            writer.close()
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])

    def test_busy_backup_obeys_deadline(self):
        writer = self.writer(wal=False)
        try:
            writer.execute("BEGIN EXCLUSIVE")
            started = time.monotonic()
            with self.assertRaises(snapshot.SnapshotUnavailable):
                self.copy(seconds=0.05)
            self.assertLess(time.monotonic() - started, 2)
        finally:
            writer.close()

    def test_unavailable_lease_fails_without_an_unsafe_copy(self):
        self.writer().close()
        with (
            self.readonly(),
            patch.object(
                snapshot,
                "read_lease",
                side_effect=OSError(errno.EOPNOTSUPP, "unsupported"),
            ),
            self.assertRaisesRegex(snapshot.SnapshotUnavailable, "safe read lease"),
        ):
            self.copy()

    def test_missing_source_is_not_created(self):
        with self.assertRaises(sqlite3.OperationalError):
            self.copy()
        self.assertFalse(self.database.exists())

    def test_interrupted_fallback_discards_partial_copy_and_retries(self):
        self.writer().close()
        real_copy = snapshot.copy_source
        attempts = []

        def copy(source, target, deadline, check):
            attempts.append(target)
            if len(attempts) == 1:
                target.write_bytes(b"partial")
                raise snapshot.LeaseBroken("fixture writer arrived")
            real_copy(source, target, deadline, check)

        with self.readonly(), patch.object(snapshot, "copy_source", side_effect=copy):
            self.copy()
            self.assertEqual(self.value(), 1)
        self.assertEqual(len(attempts), 2)
        self.assertTrue(all(not path.exists() for path in attempts))
        self.assertEqual(set(self.root.iterdir()), {self.source, self.target})


if __name__ == "__main__":
    unittest.main()

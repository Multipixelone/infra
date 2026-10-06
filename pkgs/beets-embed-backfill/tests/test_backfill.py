"""Synthetic libraries/vectors only; inference is always faked."""

import fcntl
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import beets
import beets_embed_backfill as backfill
import numpy as np
from beets import plugins
from beets.library import Item, Library
from beets_embed.store import Store, fingerprint, model_ids
from beets_embed.worker import process
from listen_queue.errors import ListenError
from listen_queue.library import open_library

beets.config.read(user=False)
beets.config["plugins"] = ["embed"]
plugins.load_plugins()


class BackfillTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.database = self.root / "library.db"
        self.store = self.root / "embeddings.sqlite3"
        self.config = {
            "library": str(self.database),
            "directory": str(self.root),
            "store": str(self.store),
        }
        library = Library(self.database, self.root)
        try:
            # An unplayed low-ID track must not outrank the high-ID played track.
            for name, plays in (("Unplayed", "0"), ("Played", "10"), ("Missing", "")):
                path = self.root / (name + ".wav")
                path.write_bytes(b"synthetic audio, never decoded")
                item = Item(
                    path=os.fsencode(path), title=name, album="Album", artist="Artist"
                )
                item["lastfm_play_count"] = plays
                library.add(item)
        finally:
            library._close()
        self.manifest = self.root / "tracks.jsonl"
        self.played_manifest = self.root / "played.jsonl"
        self.calls = []

    def stage(self, timeout=0.2, hold_timeout=15):
        backfill.stage_snapshots(
            self.config, self.manifest, self.played_manifest, timeout, hold_timeout
        )
        return list(backfill.rows(self.manifest))

    def fake_worker(self, command):
        self.calls.append(command)
        self.assertEqual(command[1], "embed")
        self.assertNotIn("--limit", command)
        manifest = Path(command[command.index("--manifest") + 1])
        tracks = list(backfill.rows(manifest))
        self.assertEqual(command[command.index("--threads") + 1], "2")
        # The native worker must be able to take an exclusive library transaction:
        # no read connection/transaction is held during inference.
        writer = sqlite3.connect(self.database, timeout=0)
        try:
            writer.execute("BEGIN EXCLUSIVE")
            writer.rollback()
        finally:
            writer.close()

        class Engine:
            @staticmethod
            def style(prepared, batch_size):
                return np.ones(4), np.zeros(4), {}, 1

            audio_text = style

        class Prepared:
            def close(self):
                pass

        with Store(self.store) as store:
            result = process(
                tracks, store, model_ids(), Engine(), lambda path: Prepared()
            )
        return 1 if result["failed"] else 0

    def execute(self, worker=None, device="cpu"):
        events = []
        with (
            patch("beetsplug.embed.run_worker", side_effect=worker or self.fake_worker),
            patch(
                "beets_embed.devices.select_worker",
                return_value=("fixture-worker", device),
            ),
            patch.object(
                backfill,
                "report",
                side_effect=lambda event, **values: events.append((event, values)),
            ),
        ):
            status = backfill.run(self.config, self.store, 2, busy_timeout=0.2)
        return status, events

    def test_snapshot_never_writes_schema_or_data(self):
        with sqlite3.connect(self.database) as writer:
            writer.execute("DROP TABLE migrations")
        before = self.database.read_bytes()
        self.assertEqual(len(self.stage()), 3)
        self.assertEqual(self.database.read_bytes(), before)
        library = open_library(self.database, self.root, read_only=True)
        try:
            with self.assertRaises(sqlite3.OperationalError):
                library._connection().execute("UPDATE items SET title='Forbidden'")
        finally:
            library._close()
        with sqlite3.connect(self.database) as reader:
            self.assertIsNone(
                reader.execute(
                    "SELECT name FROM sqlite_master WHERE name='migrations'"
                ).fetchone()
            )

    def test_reads_ignore_import_lock_and_dedicated_lock_excludes_overlap(self):
        with (self.root / ".import.lock").open("w") as import_lock:
            fcntl.flock(import_lock, fcntl.LOCK_EX)
            self.assertEqual(len(self.stage()), 3)
            with backfill.store_lock(self.store) as acquired:
                self.assertTrue(acquired)
                with backfill.store_lock(self.store) as overlapping:
                    self.assertFalse(overlapping)
                self.assertEqual(self.execute()[0], 0)
        with backfill.store_lock(self.store) as acquired:
            self.assertTrue(acquired)

    def test_reads_recover_after_concurrent_writer_releases(self):
        writer = sqlite3.connect(self.database, check_same_thread=False)
        writer.execute("BEGIN EXCLUSIVE")
        timer = threading.Timer(0.15, writer.rollback)
        timer.start()
        try:
            self.assertEqual(len(self.stage(timeout=2)), 3)
        finally:
            timer.join()
            writer.close()

    def test_tight_rollback_writer_allows_one_consistent_snapshot(self):
        stop = threading.Event()
        ready = threading.Event()
        shared = threading.Event()
        errors = []
        commits = []
        statements = []
        connect = sqlite3.connect

        def write_continuously():
            writer = connect(self.database, timeout=2)
            try:
                self.assertEqual(
                    writer.execute("PRAGMA journal_mode").fetchone()[0], "delete"
                )
                generation = 0
                while not stop.is_set():
                    generation += 1
                    writer.execute(
                        "UPDATE items SET title=? WHERE id=2", (str(generation),)
                    )
                    writer.execute(
                        "UPDATE item_attributes SET value=? WHERE entity_id=2 AND key='lastfm_play_count'",
                        (str(10 * (generation % 2)),),
                    )
                    if generation == 4:
                        # Coordinate only initial acquisition while RESERVED
                        # permits reads. Subsequent commits run in a tight loop.
                        ready.set()
                        if not shared.wait(2):
                            raise AssertionError("reader never acquired SHARED")
                    writer.commit()
                    commits.append(generation)
            except (sqlite3.Error, AssertionError) as exc:
                errors.append(exc)
                ready.set()
            finally:
                writer.close()

        class Reader(sqlite3.Connection):
            def execute(self, statement, *args):
                if statement.startswith("SELECT a.entity_id,a.value"):
                    # Give the writer ample time to reach commit between reads.
                    # Its commit must wait; it cannot change the second read.
                    time.sleep(0.05)
                cursor = super().execute(statement, *args)
                if statement == "SELECT id FROM items LIMIT 1":
                    shared.set()
                return cursor

        def read_connection(*args, **kwargs):
            self.assertTrue(kwargs["uri"])
            self.assertTrue(args[0].endswith("?mode=ro"))
            reader = connect(*args, **kwargs, factory=Reader)
            reader.set_trace_callback(statements.append)
            return reader

        writer = threading.Thread(target=write_continuously)
        writer.start()
        try:
            self.assertTrue(ready.wait(2))
            self.assertFalse(errors)
            with patch.object(backfill.sqlite3, "connect", side_effect=read_connection):
                tracks = self.stage(timeout=10)
            generation = int(next(t["title"] for t in tracks if t["id"] == 2))
            played = {t["id"] for t in backfill.rows(self.played_manifest)}
            self.assertEqual(2 in played, bool(generation % 2))
            self.assertEqual(statements.count("BEGIN"), 1)
            self.assertEqual(statements.count("COMMIT"), 1)
            self.assertEqual(sum(s.startswith("SELECT") for s in statements), 3)
            previous = len(commits)
            deadline = time.monotonic() + 2
            while len(commits) <= previous and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertGreater(len(commits), previous)
        finally:
            stop.set()
            shared.set()
            writer.join(timeout=3)
        self.assertFalse(writer.is_alive())
        self.assertFalse(errors)

    def test_hold_ceiling_interrupts_sql_and_releases_shared(self):
        connect = sqlite3.connect
        statements = []

        class SlowReader(sqlite3.Connection):
            def execute(self, statement, *args):
                if statement.startswith("SELECT id,path"):
                    super().execute(
                        "WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL "
                        "SELECT n+1 FROM numbers WHERE n<10000000) SELECT sum(n) FROM numbers"
                    ).fetchone()
                return super().execute(statement, *args)

        def read_connection(*args, **kwargs):
            reader = connect(*args, **kwargs, factory=SlowReader)
            reader.set_trace_callback(statements.append)
            return reader

        with (
            patch.object(backfill.sqlite3, "connect", side_effect=read_connection),
            self.assertRaises(ListenError) as failure,
        ):
            self.stage(timeout=1, hold_timeout=0.01)
        self.assertEqual(failure.exception.exit_code, 75)
        self.assertIn("hold limit", str(failure.exception))
        self.assertIn("ROLLBACK", statements)
        self.assertNotIn("COMMIT", statements)
        with connect(self.database, timeout=0) as writer:
            writer.execute("BEGIN EXCLUSIVE")
            writer.rollback()
        self.assertFalse(self.manifest.exists())

    def test_manifests_are_written_after_transaction_release(self):
        original_open = Path.open

        def open_manifest(path, *args, **kwargs):
            if path in (self.manifest, self.played_manifest):
                with sqlite3.connect(self.database, timeout=0) as writer:
                    writer.execute("BEGIN EXCLUSIVE")
                    writer.rollback()
            return original_open(path, *args, **kwargs)

        with patch.object(Path, "open", open_manifest):
            self.assertEqual(len(self.stage()), 3)

    def test_relative_absolute_paths_and_native_played_selection(self):
        from beetsplug.embed import snapshot

        library = Library(self.database, self.root)
        try:
            album = library.add_album(list(library.items()))
            album["lastfm_play_count"] = "7"
            album.store()
        finally:
            library._close()
        with sqlite3.connect(self.database) as writer:
            writer.execute("UPDATE items SET path=? WHERE id=1", (b"Unplayed.wav",))
            writer.execute(
                "UPDATE item_attributes SET value='0' WHERE entity_id=1 AND key='lastfm_play_count'"
            )
            writer.execute(
                "DELETE FROM item_attributes WHERE entity_id=3 AND key='lastfm_play_count'"
            )
        library = open_library(self.database, self.root, read_only=True)
        try:
            expected_all = list(snapshot(library))
            expected_played = list(
                snapshot(library, ("lastfm_play_count::^[1-9][0-9]*$",))
            )
        finally:
            library._close()
        self.assertEqual(self.stage(), expected_all)
        self.assertEqual(list(backfill.rows(self.played_manifest)), expected_played)
        self.assertEqual({track["id"] for track in expected_played}, {2, 3})
        for track in backfill.rows(self.manifest):
            self.assertTrue(Path(track["path"]).is_file())

    def test_busy_is_bounded_and_partial_snapshot_is_replaced(self):
        self.manifest.write_text("partial snapshot\n")
        with sqlite3.connect(self.database) as writer:
            writer.execute("BEGIN EXCLUSIVE")
            started = time.monotonic()
            with self.assertRaises(ListenError) as failure:
                self.stage()
            self.assertEqual(failure.exception.exit_code, 75)
            self.assertLess(time.monotonic() - started, 1)
            writer.rollback()
        self.assertEqual(len(self.stage()), 3)

    def test_wal_reads_observe_writer_without_modifying_wal(self):
        with sqlite3.connect(self.database) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("UPDATE items SET title='Changed' WHERE id=1")
            writer.commit()
            before = Path(str(self.database) + "-wal").read_bytes()
            writer.execute("BEGIN IMMEDIATE")
            self.assertEqual(self.stage()[0]["title"], "Changed")
            self.assertEqual(Path(str(self.database) + "-wal").read_bytes(), before)
            writer.rollback()

    def test_played_first_then_all_and_resume_skips_complete(self):
        before = self.database.read_bytes()
        status, events = self.execute(device="rocm")
        self.assertEqual(status, 0)
        self.assertEqual(
            [event[1]["name"] for event in events if event[0] == "pass"],
            ["played", "all"],
        )
        self.assertEqual(
            [event[1]["selected"] for event in events if event[0] == "pass"], [1, 3]
        )
        self.assertIn("--probe-passed", self.calls[0])
        self.assertEqual(events[-1][1]["complete"], 3)
        self.assertEqual(self.database.read_bytes(), before)
        self.calls.clear()
        self.assertEqual(self.execute()[0], 0)
        self.assertEqual(self.calls, [])
        self.assertFalse((self.root / ".import.lock").exists())

    def test_partial_family_and_stale_fingerprint_resume(self):
        tracks = self.stage()
        models = model_ids()
        with Store(self.store) as store:
            store.put(
                tracks[0]["id"],
                fingerprint(tracks[0]["path"]),
                models["style"],
                np.ones(4),
                np.zeros(4),
            )
            store.put(
                tracks[1]["id"],
                "old-fingerprint",
                models["text"],
                np.ones(4),
                np.zeros(4),
            )
        self.assertEqual(backfill.counts(self.manifest, self.store)["pending"], 3)
        self.assertEqual(self.execute()[0], 0)
        self.assertEqual(backfill.counts(self.manifest, self.store)["complete"], 3)
        Path(tracks[0]["path"]).write_bytes(b"changed fingerprint")
        self.assertEqual(backfill.counts(self.manifest, self.store)["pending"], 1)
        self.assertEqual(self.execute()[0], 0)

    def test_failure_continues_second_pass_and_interruption_does_not(self):
        status, events = self.execute(worker=lambda command: 1)
        self.assertEqual(status, 1)
        self.assertEqual(len([e for e in events if e[0] == "worker_exit"]), 2)
        status, events = self.execute(worker=lambda command: 143)
        self.assertEqual(status, 143)
        self.assertEqual(len([e for e in events if e[0] == "worker_exit"]), 1)
        self.assertEqual(events[-1][0], "interrupted")

    def test_unreadable_tracks_are_reported_as_failures(self):
        (self.root / "Missing.wav").unlink()
        status, events = self.execute()
        self.assertEqual(status, 1)
        self.assertEqual(events[-1][1]["unreadable"], 1)
        self.assertEqual(events[-1][1]["complete"], 2)
        with sqlite3.connect(self.store) as reader:
            complete_ids = {
                row[0] for row in reader.execute("SELECT DISTINCT item_id FROM vectors")
            }
        self.assertEqual(complete_ids, {1, 2})

    def test_native_signal_forwarding_retains_completed_work(self):
        # Standalone native signal helper; this child never imports an inference runtime.
        ready = self.root / "ready"
        retained = self.root / "retained"
        worker = self.root / "worker.py"
        worker.write_text(
            "import signal, time\nfrom pathlib import Path\n"
            f"signal.signal(signal.SIGTERM, lambda *_: (Path({str(retained)!r}).touch(), exit(143)))\n"
            f"Path({str(ready)!r}).touch()\nwhile True: time.sleep(0.01)\n"
        )
        child = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    "from beetsplug.embed import run_worker; import sys; "
                    "raise SystemExit(run_worker([sys.executable, sys.argv[1]]))"
                ),
                str(worker),
            ]
        )
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists())
            child.send_signal(signal.SIGTERM)
            self.assertEqual(child.wait(timeout=5), 143)
            self.assertTrue(retained.exists())
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()


if __name__ == "__main__":
    unittest.main()

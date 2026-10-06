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
        self.calls = []

    def stage(self, query=(), timeout=0.2):
        backfill.stage_snapshot(self.config, self.manifest, query, timeout)
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

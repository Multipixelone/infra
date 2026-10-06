"""Snapshot beets read-only, then hand inference to its packaged embed worker."""

import argparse
import fcntl
import json
import os
import re
import signal
import sqlite3
import tempfile
import time
from contextlib import contextmanager
from pathlib import Path

from listen_queue.errors import ListenError
from listen_queue.library import retry_busy

PLAYED_COUNT = re.compile(r"^[1-9][0-9]*$")


def report(event, **values):
    print(json.dumps({"event": event, **values}, sort_keys=True), flush=True)


@contextmanager
def store_lock(store):
    """Independent of the beets import lock; serialize only embedding writers."""
    path = Path(str(store) + ".backfill.lock")
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
        else:
            yield True
    finally:
        os.close(descriptor)


def snapshot_metadata(config, busy_timeout=600, hold_timeout=15):
    """Acquire SHARED once; release it before processing the captured rows."""
    deadline = time.monotonic() + busy_timeout
    attempts = 0

    def operation():
        nonlocal attempts
        attempts += 1
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise ListenError(
                "backend_unavailable", "Embedding snapshot read deadline reached.", 75
            )
        connection = sqlite3.connect(
            Path(config["library"]).resolve().as_uri() + "?mode=ro",
            uri=True,
            timeout=min(60, remaining),
        )
        connection.row_factory = sqlite3.Row
        waiting = time.monotonic()
        try:
            connection.execute("BEGIN")
            # BEGIN is deferred: this first read actually acquires SHARED. No
            # beets transaction contexts may commit between the following reads.
            connection.execute("SELECT id FROM items LIMIT 1").fetchone()
            acquired = time.monotonic()
            hold_deadline = min(deadline, acquired + hold_timeout)

            def expired():
                return time.monotonic() >= hold_deadline

            connection.set_progress_handler(expired, 1000)
            try:
                # Match the native snapshot's minimal columns. The generic
                # played query materializes every item's full flexible metadata
                # on every page; only one flexible field is needed here.
                tracks = connection.execute(
                    "SELECT id,path,album_id,artist,albumartist,album,title "
                    "FROM items WHERE id>=0 ORDER BY id"
                ).fetchall()
                # Existing unique indexes are (entity_id, key), not key alone.
                # CROSS JOIN fixes the master-table-first order so this performs
                # indexed lookups rather than scanning all xtractor attributes.
                plays = connection.execute(
                    "SELECT a.entity_id,a.value,0 AS from_album "
                    "FROM items AS i CROSS JOIN item_attributes AS a "
                    "WHERE a.entity_id=i.id AND a.key=? "
                    "UNION ALL SELECT a.entity_id,a.value,1 AS from_album "
                    "FROM albums AS i CROSS JOIN album_attributes AS a "
                    "WHERE a.entity_id=i.id AND a.key=?",
                    ("lastfm_play_count", "lastfm_play_count"),
                ).fetchall()
            except sqlite3.OperationalError as exc:
                if getattr(exc, "sqlite_errorcode", None) != sqlite3.SQLITE_INTERRUPT:
                    raise
                raise ListenError(
                    "backend_unavailable",
                    "Embedding snapshot read hold limit reached.",
                    75,
                ) from exc
            if expired():
                raise ListenError(
                    "backend_unavailable",
                    "Embedding snapshot read hold limit reached.",
                    75,
                )
            connection.set_progress_handler(None, 0)
            connection.commit()
            released = time.monotonic()
            return tracks, plays, acquired - waiting, released - acquired
        finally:
            connection.set_progress_handler(None, 0)
            try:
                connection.rollback()
            finally:
                connection.close()

    tracks, plays, waiting, held = retry_busy(operation, busy_timeout)
    report(
        "snapshot",
        selected=len(tracks),
        attempts=attempts,
        wait_seconds=round(waiting, 3),
        read_hold_seconds=round(held, 3),
    )
    return tracks, plays


def stage_snapshots(
    config, manifest, played_manifest, busy_timeout=600, hold_timeout=15
):
    tracks, plays = snapshot_metadata(config, busy_timeout, hold_timeout)
    item_plays = {
        row["entity_id"]: row["value"] for row in plays if not row["from_album"]
    }
    album_plays = {row["entity_id"]: row["value"] for row in plays if row["from_album"]}
    # Filesystem access and JSON serialization happen after COMMIT and close.
    # Normalize paths exactly like the native SQL snapshot; absolute paths keep
    # their root, while relative paths resolve against the music directory.
    with manifest.open("w") as output, played_manifest.open("w") as played_output:
        for row in tracks:
            track = dict(row)
            track["path"] = os.path.normpath(
                os.path.join(
                    os.fsdecode(config["directory"]), os.fsdecode(track["path"])
                )
            )
            line = json.dumps(track, ensure_ascii=True) + "\n"
            output.write(line)
            # An explicit item value (including zero) overrides the album, just
            # like Item.get in the native played query.
            plays = item_plays.get(track["id"], album_plays.get(track["album_id"]))
            if PLAYED_COUNT.search(str(plays)):
                played_output.write(line)


def rows(manifest):
    with manifest.open() as source:
        yield from (json.loads(line) for line in source)


def counts(manifest, store):
    from beets_embed.store import count_pending, model_ids

    return count_pending(rows(manifest), str(store), model_ids())


def run(config, store, threads, busy_timeout=600):
    import beets
    from beets import plugins

    # Do not use ui._open_library: ordinary beets startup executes schema DDL.
    # Only embed participates; no import/database_change hooks or secrets needed.
    beets.config.read(user=False)
    beets.config["plugins"] = ["embed"]
    beets.config["timeout"] = 0
    plugins.load_plugins()
    from beets_embed.devices import select_worker
    from beetsplug.embed import WORKER, run_worker

    with tempfile.TemporaryDirectory(prefix="beets-embed-backfill-") as temporary:
        all_tracks = Path(temporary) / "all.jsonl"
        played_tracks = Path(temporary) / "played.jsonl"
        stage_snapshots(config, all_tracks, played_tracks, busy_timeout=busy_timeout)
        before = counts(all_tracks, store)
        report("initial", **before)
        if before["pending"] == 0:
            report("complete", **before)
            return 1 if before["unreadable"] else 0
        # No beets connection survives snapshot staging, including device probing.
        worker, device = select_worker("auto", WORKER)
        report("device", device=device, threads=threads, batch_size=8)
        status = 0
        for name, manifest in (("played", played_tracks), ("all", all_tracks)):
            pending = counts(manifest, store)
            report("pass", name=name, **pending)
            if pending["pending"] == 0:
                continue
            command = [
                worker,
                "embed",
                "--manifest",
                str(manifest),
                "--store",
                str(store),
                "--threads",
                str(threads),
                "--batch-size",
                "8",
                "--device",
                device,
            ]
            if device == "rocm":
                command.append("--probe-passed")
            result = run_worker(command)
            report("worker_exit", name=name, status=result)
            if result in (143, -signal.SIGTERM, 130, -signal.SIGINT):
                report("interrupted", **counts(all_tracks, store))
                return 143 if result in (143, -signal.SIGTERM) else 130
            if result:
                status = 1
            # Errors do not starve the second pass; native per-track/failure JSON
            # remains in the journal and completed families remain committed.
        after = counts(all_tracks, store)
        report("final", **after)
        return status or (1 if after["unreadable"] else 0)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--threads", type=int, default=2, choices=range(1, 17))
    args = parser.parse_args(argv)
    try:
        config = json.loads(args.config.read_text())
        store = Path(config["store"])
        with store_lock(store) as acquired:
            if not acquired:
                report(
                    "overlap", message="Embedding store lock busy; skipping this run"
                )
                return 0
            return run(config, store, args.threads)
    except ListenError as exc:
        report("read_error", message=str(exc), status=exc.exit_code)
        return exc.exit_code
    except (OSError, ValueError, sqlite3.Error) as exc:
        report("error", message=str(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

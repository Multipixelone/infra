"""Snapshot beets read-only, then hand inference to its packaged embed worker."""

import argparse
import fcntl
import json
import os
import signal
import sqlite3
import tempfile
from contextlib import contextmanager
from pathlib import Path

from listen_queue.errors import ListenError
from listen_queue.library import open_library, retry_busy

PLAYED_QUERY = ("lastfm_play_count::^[1-9][0-9]*$",)


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


def stage_snapshot(config, manifest, query=(), busy_timeout=10):
    from beetsplug.embed import snapshot

    def operation():
        library = open_library(config["library"], config["directory"], read_only=True)
        try:
            # Truncate on every retry: never retain a partial snapshot or duplicate
            # pages. Native snapshot queries release their transaction every 512 IDs.
            with manifest.open("w") as output:
                for track in snapshot(library, query):
                    output.write(json.dumps(track, ensure_ascii=True) + "\n")
        finally:
            library._close()

    # This uses listen's zero-wait SQLite connections and bounded busy retry,
    # never the long timeout inherited from the importer configuration.
    retry_busy(operation, busy_timeout)


def rows(manifest):
    with manifest.open() as source:
        yield from (json.loads(line) for line in source)


def counts(manifest, store):
    from beets_embed.store import count_pending, model_ids

    return count_pending(rows(manifest), str(store), model_ids())


def run(config, store, threads, busy_timeout=10):
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
        stage_snapshot(config, all_tracks, busy_timeout=busy_timeout)
        before = counts(all_tracks, store)
        report("initial", **before)
        if before["pending"] == 0:
            report("complete", **before)
            return 1 if before["unreadable"] else 0
        stage_snapshot(config, played_tracks, PLAYED_QUERY, busy_timeout)
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

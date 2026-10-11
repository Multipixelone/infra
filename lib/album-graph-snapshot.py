"""Back up live SQLite inputs without an import lock or writable sidecars."""

import argparse
import errno
import fcntl
import json
import math
import os
import signal
import sqlite3
import sys
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path


class SnapshotUnavailable(Exception):
    pass


class LeaseBroken(Exception):
    pass


@contextmanager
def read_lease(path):
    """Protect file copies only while the kernel excludes writable opens.

    Read-only WAL needs either existing readable sidecars or a writable
    directory. A read lease allows a stable private copy of the database and
    WAL: an existing writable handle prevents admission, and a new writer
    requests a break. Never ignore that break or wait out the kernel grace.
    """
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
    broken = False

    def break_requested(signum, frame):
        nonlocal broken
        broken = True

    previous = signal.signal(signal.SIGIO, break_requested)
    acquired = False
    try:
        fcntl.fcntl(descriptor, fcntl.F_SETOWN, os.getpid())
        fcntl.fcntl(descriptor, fcntl.F_SETLEASE, fcntl.F_RDLCK)
        acquired = True

        def check():
            state = fcntl.fcntl(descriptor, fcntl.F_GETLEASE)
            if broken or state != fcntl.F_RDLCK:
                raise LeaseBroken("A writer requested the snapshot read lease")

        yield check
        check()
    finally:
        if acquired:
            fcntl.fcntl(descriptor, fcntl.F_SETLEASE, fcntl.F_UNLCK)
        os.close(descriptor)
        signal.signal(signal.SIGIO, previous)


def check_deadline(deadline):
    if time.monotonic() >= deadline:
        raise SnapshotUnavailable("SQLite snapshot deadline reached")


def backup(source, target, deadline):
    uri = Path(source).resolve().as_uri() + "?mode=ro"

    def check(status=None, remaining=None, total=None):
        check_deadline(deadline)

    check()
    reader = sqlite3.connect(uri, uri=True, timeout=1)
    try:
        while True:
            check()
            try:
                if reader.execute("PRAGMA journal_mode").fetchone()[0] == "wal":
                    # An orphaned read-only SHM with an empty WAL invalidates
                    # SQLite's cache at every new read transaction, restarting
                    # a stepped backup even without a writer. Pin one WAL
                    # snapshot; BEGIN alone does not establish a read lock.
                    reader.execute("BEGIN")
                    reader.execute(
                        "SELECT rootpage FROM sqlite_schema LIMIT 1"
                    ).fetchone()
                break
            except sqlite3.OperationalError as exc:
                reader.rollback()
                if getattr(exc, "sqlite_errorcode", 0) & 0xFF not in (
                    sqlite3.SQLITE_BUSY,
                    sqlite3.SQLITE_LOCKED,
                ):
                    raise
                check()
                time.sleep(0.1)
        check()
        writer = sqlite3.connect(target)
        try:
            os.chmod(target, 0o600)
            # WAL writers can still commit; checkpointing waits for our reader
            # to close. Rollback databases retain short read-lock batches.
            reader.backup(writer, pages=256, progress=check, sleep=0.1)
            check()
        finally:
            writer.close()
    finally:
        reader.close()


def copy_source(source, target, deadline, check_lease):
    # A lease break must discard the entire copy, including any WAL. Exclude
    # SHM: SQLite rebuilds that coordination state inside our writable staging.
    for suffix in ("", "-wal", "-journal"):
        path = Path(str(source) + suffix)
        if suffix and not path.exists():
            continue
        check_deadline(deadline)
        check_lease()
        with (
            path.open("rb") as reader,
            Path(str(target) + suffix).open("xb") as writer,
        ):
            os.chmod(writer.name, 0o600)
            while True:
                check_deadline(deadline)
                check_lease()
                chunk = reader.read(1024 * 1024)
                if not chunk:
                    break
                writer.write(chunk)
        check_lease()


def snapshot(source, target, deadline):
    # SQLite resolves database symlinks before locating WAL and journal files.
    source = source.resolve()
    sidecar_errors = {
        sqlite3.SQLITE_READONLY_DIRECTORY,
        sqlite3.SQLITE_READONLY_CANTINIT,
        sqlite3.SQLITE_CANTOPEN,
    }
    while True:
        target.unlink(missing_ok=True)
        try:
            backup(source, target, deadline)
            return
        except sqlite3.OperationalError as exc:
            sidecar_failure = getattr(exc, "sqlite_errorcode", None) in sidecar_errors
            if not sidecar_failure or not source.is_file():
                raise

        target.unlink(missing_ok=True)
        try:
            with tempfile.TemporaryDirectory(dir=target.parent) as directory:
                private_source = Path(directory) / "source.db"
                with read_lease(source) as check:
                    copy_source(source, private_source, deadline, check)
                # The live source is already closed and its lease released.
                # SQLite may create private sidecars, including without a WAL.
                backup(private_source, target, deadline)
            print(f"Snapshot used a protected file copy: {source}", flush=True)
            return
        except LeaseBroken:
            pass
        except OSError as exc:
            if exc.errno != errno.EAGAIN:
                raise SnapshotUnavailable(
                    "Read-only WAL sidecars are unavailable and this filesystem "
                    f"cannot provide a safe read lease: {exc}"
                ) from exc
        if time.monotonic() >= deadline:
            raise SnapshotUnavailable("SQLite snapshot deadline reached")
        time.sleep(0.1)


def valid_epoch(value):
    if isinstance(value, bool):
        return None
    try:
        value = float(value)
        if math.isfinite(value) and value > 0:
            datetime.fromtimestamp(value, timezone.utc)
            return value
    except (ValueError, TypeError, OverflowError, OSError):
        pass
    return None


def first_played(added, lastfm):
    added, lastfm = valid_epoch(added), valid_epoch(lastfm)
    if lastfm is not None and (added is None or lastfm <= added):
        value, source = lastfm, "lastfm"
    elif added is not None:
        value, source = added, "added"
    else:
        return None, None
    return datetime.fromtimestamp(value, timezone.utc).date().isoformat(), source


def enrich_first_played(library, output):
    """Add dates from the same private snapshot used by the embed exporter."""
    data = json.loads(output.read_text())
    uri = library.resolve().as_uri() + "?mode=ro"
    reader = sqlite3.connect(uri, uri=True)
    try:
        dates = {
            album_id: first_played(added, lastfm)
            for album_id, added, lastfm in reader.execute(
                "SELECT a.id, a.added, f.value FROM albums AS a "
                "LEFT JOIN album_attributes AS f ON f.entity_id=a.id "
                "AND f.key='lastfm_first_played'"
            )
        }
    finally:
        reader.close()
    for album in data["albums"]:
        album["first_played"], album["first_played_source"] = dates.get(
            album["id"], (None, None)
        )
    # The launcher publishes only after this succeeds; preserve every other key.
    fd, temporary = tempfile.mkstemp(prefix=".first-played-", dir=output.parent)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(data, handle, ensure_ascii=False, allow_nan=False)
            handle.write("\n")
        os.replace(temporary, output)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main():
    if sys.argv[1:2] == ["enrich-first-played"]:
        parser = argparse.ArgumentParser(
            description="Enrich staged graph JSON with first-played dates"
        )
        parser.add_argument("library", type=Path)
        parser.add_argument("output", type=Path)
        args = parser.parse_args(sys.argv[2:])
        try:
            enrich_first_played(args.library, args.output)
        except (sqlite3.Error, OSError, ValueError, KeyError, TypeError):
            parser.exit(75, "Album graph first-played enrichment failed\n")
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path)
    parser.add_argument("store", type=Path)
    parser.add_argument("staging", type=Path)
    parser.add_argument("--timeout", type=float, default=300)
    args = parser.parse_args()
    started = time.monotonic()
    deadline = started + args.timeout
    try:
        for source, name in (
            (args.library, "library.db"),
            (args.store, "embeddings.sqlite3"),
        ):
            print(f"Snapshot started: {source}", flush=True)
            snapshot(source, args.staging / name, deadline)
            print(f"Snapshot completed: {source}", flush=True)
    except (sqlite3.Error, OSError, SnapshotUnavailable) as exc:
        parser.exit(75, f"Album graph snapshot failed: {exc}\n")
    elapsed = time.monotonic() - started
    print(f"Snapshots completed in {elapsed:.3f}s", flush=True)


if __name__ == "__main__":
    main()

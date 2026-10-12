"""Publish a consistent online SQLite snapshot without stopping Grimoire."""

import argparse
import os
import sqlite3
import sys
import tempfile
from contextlib import closing
from pathlib import Path
from time import monotonic


def snapshot(source: Path, destination: Path, timeout_seconds: float = 300) -> None:
    """Keep the previous snapshot until a complete, checked replacement exists.

    The destination directory is root-owned and provisioned by NixOS. Never
    create it here or write temporary files into application-controlled state.
    Opening the source read-only also prevents a missing DB becoming an empty
    but apparently successful backup.
    """
    deadline = monotonic() + timeout_seconds
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}-", suffix=".tmp", dir=destination.parent
    )
    os.close(fd)
    temporary = Path(temporary_name)

    def progress(_status: int, _remaining: int, _total: int) -> None:
        if monotonic() >= deadline:
            raise TimeoutError("SQLite snapshot exceeded its time limit")

    try:
        with (
            closing(
                sqlite3.connect(source.absolute().as_uri() + "?mode=ro", uri=True)
            ) as live,
            closing(sqlite3.connect(temporary)) as saved,
        ):
            live.backup(saved, pages=256, progress=progress, sleep=0.1)
            saved.set_progress_handler(lambda: int(monotonic() >= deadline), 10000)
            if saved.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise RuntimeError("SQLite snapshot failed its integrity check")
            # The snapshot is one standalone file, even when the source
            # uses WAL. Finish journal changes before publishing it.
            saved.execute("PRAGMA journal_mode=DELETE")
        with temporary.open("rb") as saved_file:
            os.fsync(saved_file.fileno())
        os.replace(temporary, destination)
        directory_fd = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        for suffix in ("", "-wal", "-shm", "-journal"):
            Path(str(temporary) + suffix).unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        snapshot(args.source, args.destination)
    except (OSError, sqlite3.Error, RuntimeError, TimeoutError) as error:
        print(f"Grimoire SQLite backup failed: {error}", file=sys.stderr)
        return 1
    print("Grimoire SQLite snapshot integrity check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

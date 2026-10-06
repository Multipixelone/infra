"""Beets configuration, album metadata, shared locking, and private receipts."""

import fcntl
import json
import math
import os
import sqlite3
import tempfile
import time
import unicodedata
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path

from .errors import ListenError, invalid

RESERVED = {"bpm", "mirex_cluster", "rosamerica"} | {f"mirex_{i}" for i in range(1, 6)}


def normalize(text):
    decomposed = unicodedata.normalize("NFKD", str(text).casefold())
    return " ".join(
        "".join(c for c in decomposed if not unicodedata.combining(c)).split()
    )


def number(value, *, positive=False, score=False):
    try:
        result = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    if not math.isfinite(result) or (positive and result <= 0):
        return None
    if score and not 0 <= result <= 1:
        return None
    return result


def timestamp(value):
    value = number(value, positive=True)
    if value is None:
        return None
    try:
        return (
            datetime.fromtimestamp(value, timezone.utc)
            .isoformat()
            .replace("+00:00", "Z")
        )
    except (ValueError, OverflowError, OSError):
        return None


def now_stamp():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def play_count(item):
    """Prefer current lastimport counts; retain legacy counts without summing."""
    for field in ("lastfm_play_count", "play_count"):
        raw = item.get(field, None, with_album=False)
        if isinstance(raw, bool):
            continue
        value = number(raw)
        if value is not None and value >= 0 and value.is_integer():
            return int(value)
    return 0


def timeout_setting(name, default):
    value = number(os.environ.get(name, default))
    if value is None or value < 0:
        raise ListenError(
            "configuration_invalid", f"{name} must be finite and nonnegative.", 78
        )
    return value


@contextmanager
def shared_lock(path, timeout=30, *, message=None):
    """Acquire an exclusive lock without waiting indefinitely."""
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ListenError(
                        "backend_unavailable",
                        message
                        or "Beets is busy (import/backfill running); try again later.",
                        75,
                    ) from None
                time.sleep(min(0.05, remaining))
        yield
    finally:
        os.close(fd)


@contextmanager
def state_lock(root):
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with shared_lock(
        root / ".lock", 5, message="Listen state is busy; try again later."
    ):
        yield


def retry_busy(operation, timeout):
    """Retry a read operation, never a database mutation, on SQLite contention."""
    deadline = time.monotonic() + timeout
    delay = 0.05
    while True:
        try:
            return operation()
        except sqlite3.OperationalError as exc:
            code = getattr(exc, "sqlite_errorcode", None)
            # Mask extended result codes (e.g. SQLITE_BUSY_SNAPSHOT). The
            # message fallback covers SQLite errors raised by beets/tests.
            busy = (
                code & 0xFF in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED)
                if code is not None
                else str(exc).lower()
                in (
                    "database is locked",
                    "database is busy",
                    "database table is locked",
                )
            )
            if not busy:
                raise
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ListenError(
                    "backend_unavailable",
                    "Beets database is busy; read retry limit reached. Try again later.",
                    75,
                ) from None
            time.sleep(min(delay, remaining))
            delay = min(delay * 2, 0.5)


def open_library(path, directory, read_only):
    from beets.library import Library

    class ReadOnlyLibrary(Library):
        """Adapter for pinned beets, whose constructor otherwise runs DDL."""

        def _create_connection(self):
            # Keep self.path as the real path for beets; URI encoding also
            # handles filenames containing '?' or '#'. Do not use immutable:
            # the library can change underneath this reader, including in WAL.
            conn = sqlite3.connect(
                Path(self.path).resolve().as_uri() + "?mode=ro",
                uri=True,
                timeout=0,
                check_same_thread=False,
            )
            conn.row_factory = sqlite3.Row
            self.add_functions(conn)
            return conn

        def _ensure_migration_state_table(self):
            pass

        def _make_table(self, table, fields):
            pass

        def _make_attribute_table(self, flex_table):
            pass

        def _create_indices(self, table, indices):
            pass

        def _migrate(self):
            pass

    cls = ReadOnlyLibrary if read_only else Library
    # Close partially initialized libraries too if constructor/schema access
    # fails, so a retry cannot retain connections or SQLite locks.
    library = cls.__new__(cls)
    try:
        cls.__init__(library, path, directory)
    except BaseException:
        if hasattr(library, "_connections"):
            library._close()
        raise
    return library


class State:
    def __init__(self, root, library):
        self.root = Path(root)
        self.library = os.path.realpath(library)

    def read(self, name):
        try:
            fd = os.open(self.root / name, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            return None
        try:
            with os.fdopen(fd) as handle:
                data = json.load(handle)
            if not isinstance(data, dict) or data.get("schema") != 1:
                raise ValueError("Invalid receipt schema")
            if data.get("library") != self.library:
                raise ValueError("Receipt belongs to another beets library")
            return data
        except (ValueError, TypeError) as exc:
            raise ListenError("state_invalid", f"Invalid {name} receipt.", 78) from exc

    def write(self, name, **values):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, temporary = tempfile.mkstemp(prefix=".listen-", dir=self.root)
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump({"schema": 1, "library": self.library, **values}, handle)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.root / name)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def clear_pick(self):
        (self.root / "last-pick.json").unlink(missing_ok=True)


class Queue:
    def __init__(self, config_path, state_root, *, read_only=False):
        import beets
        from beets import plugins

        if not Path(config_path).is_file():
            raise ListenError(
                "configuration_invalid", "Beets configuration is missing.", 78
            )
        # Do not instantiate plexsync, hook, smartplaylist, or acquisition plugins.
        # The same library/config is used, but only our required computed/types
        # plugins participate in database_change events.
        beets.config.read(user=False)
        beets.config.set_file(str(config_path))
        if beets.config["include"].exists():
            for view in beets.config["include"].sequence():
                beets.config.set_file(view.as_filename())
        beets.config["plugins"] = ["types", "inline"]
        plugins.load_plugins()
        dbpath = beets.config["library"].as_filename()
        if not Path(dbpath).is_file():
            raise ListenError(
                "configuration_invalid", "Beets library database is missing.", 78
            )
        self.state = State(state_root, dbpath)
        self.fields = {
            name.removeprefix("listen_"): name
            for name in beets.config["album_fields"].get(dict)
            if name.startswith("listen_")
            and name.removeprefix("listen_") not in RESERVED
            and not name.endswith("_scored_tracks")
        }
        # Never inherit an hours-long SQLite timeout from the import config.
        beets.config["timeout"] = (
            0 if read_only else min(5, max(0, beets.config["timeout"].as_number()))
        )
        self.lib = open_library(
            dbpath, beets.config["directory"].as_filename(), read_only
        )

    def close(self):
        self.lib._close()

    def metadata(
        self,
        album,
        *,
        score_names=None,
        tracks=True,
        play_history=True,
        bpm=True,
        classifiers=True,
    ):
        """Project only needed fields while ranking; defaults return full metadata.

        Inline fields each query album tracks, so library-wide graph queries must
        not evaluate every classifier before selecting a handful of results.
        Discovery hydrates those results with the default projection afterward.
        """
        items = list(album.items()) if tracks else []
        lengths = [number(item.length, positive=True) for item in items]
        plays = sum(play_count(item) for item in items) if play_history else 0
        scores = {
            name: self.score(album, field)
            for name, field in sorted(self.fields.items())
            if score_names is None or name in score_names
        }
        genre_values = list(album.get("genres") or [])
        if isinstance(album.get("genres"), str):
            genre_values = [album.get("genres")]
        if album.get("genre"):
            genre_values.append(album.genre)
        return {
            "id": album.id,
            "albumartist": album.albumartist,
            "album": album.album,
            "year": album.year or None,
            "track_count": len(items),
            "play_count": plays,
            "plays_per_track": plays / len(items) if items else None,
            "length_seconds": sum(lengths)
            if lengths and all(v is not None for v in lengths)
            else None,
            "genres": sorted(set(genre_values)),
            "label": album.label or None,
            "added": timestamp(album.added),
            "bpm": number(album.get("listen_bpm"), positive=True) if bpm else None,
            "listen_state": album.get("listen_state") or None,
            "listened_at": timestamp(album.get("listened_at")),
            "scores": scores,
            "mood_mirex": {
                "cluster": album.get("listen_mirex_cluster") if classifiers else None,
                "scores": {
                    str(i): self.score(album, f"listen_mirex_{i}") for i in range(1, 6)
                }
                if classifiers
                else {},
            },
            "genre_rosamerica": {
                "genre": (album.get("listen_rosamerica") or None)
                if classifiers
                else None,
                "present": bool(album.get("listen_rosamerica"))
                if classifiers
                else False,
                "scored_tracks": int(album.get("listen_rosamerica_scored_tracks") or 0)
                if classifiers
                else 0,
            },
        }

    @staticmethod
    def score(album, field):
        value = number(album.get(field), score=True)
        return {
            "score": value,
            "present": value is not None,
            "scored_tracks": int(album.get(field + "_scored_tracks") or 0),
        }

    def albums(self, state="queued"):
        return [
            album
            for album in self.lib.albums()
            if state == "all" or album.get("listen_state") == state
        ]

    def most_played(self, listened_only=False):
        albums = [
            self.metadata(album)
            for album in self.albums("listened" if listened_only else "all")
        ]
        if not listened_only:
            albums = [album for album in albums if album["play_count"] > 0]
        albums.sort(
            key=lambda album: (
                -album["play_count"],
                normalize(album["albumartist"]),
                normalize(album["album"]),
                album["id"],
            )
        )
        return {"basis": "listened" if listened_only else "played", "albums": albums}

    def resolve(self, text=None, album_id=None):
        if album_id is not None:
            album = self.lib.get_album(album_id)
            if album is None:
                raise ListenError("not_found", "Album ID was not found.", 65)
            return album
        terms = normalize(text or "").split()
        if not terms:
            raise invalid("Supply nonempty album text or --id.")
        matches = []
        for album in self.lib.albums():
            haystack = normalize(f"{album.albumartist} {album.album}")
            if all(term in haystack for term in terms):
                matches.append(album)
        if not matches:
            raise ListenError("not_found", "No album matched.", 65)
        if len(matches) > 1:
            raise ListenError(
                "ambiguous",
                "Multiple albums matched; choose --id.",
                candidates=[self.metadata(a) for a in matches],
            )
        return matches[0]

    def mark(self, command, text=None, album_id=None):
        if command != "add" and text is None and album_id is None:
            receipt = self.state.read("last-pick.json")
            picked_id = receipt.get("album_id") if receipt else None
            if not isinstance(picked_id, int) or picked_id <= 0:
                raise ListenError(
                    "needs_album", "Choose an album with pick --choose ID first."
                )
            album = self.lib.get_album(picked_id)
            if album is None or album.get("listen_state") != "queued":
                self.state.clear_pick()
                raise ListenError(
                    "needs_album",
                    "The saved album is no longer queued; choose an album.",
                )
        else:
            album = self.resolve(text, album_id)
        with self.lib.transaction():
            album["listen_state"] = {
                "add": "queued",
                "done": "listened",
                "drop": "dropped",
            }[command]
            if command == "done":
                album["listened_at"] = datetime.now(timezone.utc).timestamp()
            album.store(inherit=False)
        # A crash between DB commit and clearing is safe: bare marking checks
        # that the saved album is still queued before changing it again.
        if command != "add":
            self.state.clear_pick()
        return {"album": self.metadata(album)}

    def choose(self, album_id):
        album = self.resolve(album_id=album_id)
        if album.get("listen_state") != "queued":
            raise ListenError("not_queued", "Only queued albums can be chosen.")
        # Complete every database read before writing: read retries must never
        # replay a receipt mutation after a late busy error in metadata().
        chosen = self.metadata(album)
        self.state.write("last-pick.json", album_id=album.id, picked_at=now_stamp())
        return {"mode": "choose", "chosen": chosen}

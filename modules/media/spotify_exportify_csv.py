"""Validate an Exportify CSV and write a private, album-ID-keyed JSON manifest.

CLI: --input CSV_PATH --output JSON_PATH [--against MUTABLE_PATH]...
The caller supplies every other mutable importer path with --against. No path
is written until the entire CSV and path collision checks have passed.
"""

import argparse
import csv
import io
import json
import os
import re
import stat
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import NoReturn

REQUIRED_HEADERS = ("Track URI", "Album URI", "Album Name", "Album Artist Name(s)")
TRACK_URI = re.compile(r"spotify:track:([A-Za-z0-9]{22})\Z")
ALBUM_URI = re.compile(r"spotify:album:([A-Za-z0-9]{22})\Z")


class ImportError(ValueError):
    """A safe, user-facing validation error (never includes input contents)."""


def fail(line, message) -> NoReturn:
    raise ImportError(f"line {line}: {message}")


def parse_csv(source):
    reader = csv.reader(source, strict=True)
    albums = {}
    skipped = Counter(blank=0, local=0, episode=0, unavailable=0)
    rows = 0
    line = 1
    try:
        headers = next(reader, None)
        if headers is None:
            fail(1, "missing Exportify header")
        if len(headers) != len(set(headers)):
            fail(1, "duplicate CSV headers")
        if "Album Artist Name(s)" not in headers:
            fail(
                1, "missing Album Artist Name(s); re-export using current exportify.app"
            )
        if any(header not in headers for header in REQUIRED_HEADERS):
            fail(1, "missing required Exportify headers")
        indexes = [headers.index(header) for header in REQUIRED_HEADERS]
        while True:
            line = reader.line_num + 1
            row = next(reader, None)
            if row is None:
                break
            rows += 1
            if not row or all(not value.strip() for value in row):
                skipped["blank"] += 1
                continue
            if len(row) != len(headers):
                fail(line, "CSV row has wrong number of columns")
            track, album, name, artist = (row[index].strip() for index in indexes)
            if track.startswith("spotify:local:"):
                skipped["local"] += 1
                continue
            if track.startswith("spotify:episode:"):
                skipped["episode"] += 1
                continue
            if track and not TRACK_URI.fullmatch(track):
                fail(line, "malformed Track URI")
            match = ALBUM_URI.fullmatch(album)
            if album and match is None:
                fail(line, "malformed Album URI")
            if not track or not album:
                skipped["unavailable"] += 1
                continue
            assert match is not None
            if not name or not artist:
                fail(line, "album name and album artist must not be blank")
            album_id = match.group(1)
            record = {
                "spotify_id": album_id,
                "name": name,
                "artist": artist,
                "spotify_url": f"https://open.spotify.com/album/{album_id}",
            }
            if album_id in albums and albums[album_id] != record:
                fail(line, "conflicting metadata for the same album ID")
            albums[album_id] = record
    except UnicodeError:
        fail(line, "CSV must be valid UTF-8")
    except csv.Error:
        fail(line, "malformed CSV")
    if not albums:
        fail(max(1, reader.line_num), "no usable albums in Exportify CSV")
    return [albums[key] for key in sorted(albums)], rows, skipped


def aliases(left, right):
    if left.resolve() == right.resolve():
        return True
    try:
        return left.samefile(right)
    except FileNotFoundError:
        return False


def validate_paths(source, output, against):
    if not stat.S_ISREG(source.stat().st_mode):
        fail(1, "input must be a readable regular local file")
    for mutable in [output, *against]:
        if aliases(source, mutable):
            fail(1, "input aliases a mutable importer path")
    for mutable in against:
        if aliases(output, mutable):
            fail(1, "output aliases a protected importer path")
    if output.exists() and not stat.S_ISREG(output.stat().st_mode):
        fail(1, "output must be a regular file")


def convert(source, output, against=()):
    source, output = Path(source), Path(output)
    against = [Path(path) for path in against]
    # O_NONBLOCK prevents FIFO input from hanging, including a stat/open race.
    if not stat.S_ISREG(source.stat().st_mode):
        fail(1, "input must be a readable regular local file")
    fd = os.open(source, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as binary:
        if not stat.S_ISREG(os.fstat(binary.fileno()).st_mode):
            fail(1, "input must be a readable regular local file")
        with io.TextIOWrapper(binary, encoding="utf-8-sig", newline="") as text:
            albums, rows, skipped = parse_csv(text)
    validate_paths(source, output, against)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=output.parent, delete=False
        ) as stream:
            temporary = Path(stream.name)
            json.dump(albums, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.replace(temporary, output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return albums, rows, skipped


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--against", action="append", default=[], type=Path)
    args = parser.parse_args(argv)
    try:
        albums, rows, skipped = convert(args.input, args.output, args.against)
    except ImportError as error:
        print(f"exportify-csv: {error}", file=sys.stderr)
        return 1
    except (OSError, RuntimeError):
        print(
            "exportify-csv: line 1: cannot read input or validate/write local paths",
            file=sys.stderr,
        )
        return 1
    counts = ", ".join(f"{reason}={count}" for reason, count in skipped.items())
    print(
        f"exportify-csv: rows={rows}, albums={len(albums)}, skipped: {counts}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

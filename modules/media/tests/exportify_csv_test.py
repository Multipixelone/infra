"""Focused stdlib tests; run with python -B modules/media/tests/exportify_csv_test.py."""

import csv
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "spotify_exportify_csv.py"
SPEC = importlib.util.spec_from_file_location("exportify_csv", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
parser = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(parser)
HEADERS = list(parser.REQUIRED_HEADERS)
ID_A = "0123456789ABCDEFGHIJKL"
ID_B = "abcdefghijklmnopqrstuv"
TRACK = "spotify:track:" + ID_A


def record(album_id=ID_A, name="Album", artist="Artist"):
    return [TRACK, "spotify:album:" + album_id, name, artist]


def csv_text(rows, headers=HEADERS):
    stream = io.StringIO(newline="")
    writer = csv.writer(stream, lineterminator="\r\n")
    writer.writerow(headers)
    writer.writerows(rows)
    return stream.getvalue()


class ParserTests(unittest.TestCase):
    def parse(self, rows, headers=HEADERS):
        return parser.parse_csv(io.StringIO(csv_text(rows, headers), newline=""))

    def test_metadata_sorting_and_id_dedup(self):
        name = '  日本語, "title"\r\nsecond line  '
        artist = "  Björk, Artist; Someone\nElse  "
        albums, rows, skipped = self.parse(
            [
                record(ID_B, name, artist),
                record(ID_A, name, artist),
                record(ID_B, name, artist),
            ]
        )
        self.assertEqual([item["spotify_id"] for item in albums], [ID_A, ID_B])
        self.assertEqual(
            albums[0],
            {
                "spotify_id": ID_A,
                "name": name.strip(),
                "artist": artist.strip(),
                "spotify_url": "https://open.spotify.com/album/" + ID_A,
            },
        )
        self.assertEqual(rows, 3)
        self.assertEqual(sum(skipped.values()), 0)

    def test_header_order_and_extra_columns(self):
        headers = ["Extra", *reversed(HEADERS)]
        albums, _, _ = self.parse([["ignored", *reversed(record())]], headers)
        self.assertEqual(albums[0]["spotify_id"], ID_A)

    def test_skip_reasons(self):
        _, rows, counts = self.parse(
            [
                [],
                [" "] * 4,
                ["spotify:local:anything", "bad", "", ""],
                ["spotify:episode:anything", "bad", "", ""],
                ["", "spotify:album:" + ID_A, "", ""],
                [TRACK, "", "", ""],
                record(),
            ]
        )
        self.assertEqual(rows, 7)
        self.assertEqual(
            dict(counts), {"blank": 2, "local": 1, "episode": 1, "unavailable": 2}
        )

    def test_bad_uris(self):
        for column in (0, 1):
            for bad in (
                "https://open.spotify.com/album/" + ID_A,
                "spotify:album:short",
                "spotify:track:" + "!" * 22,
                "spotify:album:" + "é" * 22,
                "spotify:album:" + ID_A + "x",
            ):
                with self.subTest(column=column, bad=bad):
                    row = record()
                    row[column] = bad
                    with self.assertRaisesRegex(
                        parser.ImportError, "line 2: malformed"
                    ):
                        self.parse([row])

    def test_missing_identity_does_not_hide_malformed_nonempty_uri(self):
        for row in (["", "bad", "", ""], ["bad", "", "", ""]):
            with self.assertRaisesRegex(parser.ImportError, "malformed"):
                self.parse([row])

    def test_blank_metadata(self):
        for column in (2, 3):
            row = record()
            row[column] = " \n "
            with self.assertRaisesRegex(parser.ImportError, "line 2:.*blank"):
                self.parse([row])

    def test_conflicting_metadata(self):
        for row in (record(name="different"), record(artist="different")):
            with self.assertRaisesRegex(parser.ImportError, "line 3: conflicting"):
                self.parse([record(), row])

    def test_bad_headers(self):
        for headers in (HEADERS + [HEADERS[0]], HEADERS[1:]):
            with self.assertRaises(parser.ImportError):
                self.parse([], headers)
        with self.assertRaisesRegex(
            parser.ImportError, "re-export using current exportify.app"
        ):
            self.parse([], HEADERS[:-1] + ["Artist Name(s)"])

    def test_wrong_arity(self):
        for row in (record()[:-1], record() + ["extra"]):
            with self.assertRaisesRegex(parser.ImportError, "line 2:.*columns"):
                self.parse([row])

    def test_empty_header_only_and_all_skipped(self):
        for text in (
            "",
            csv_text([]),
            csv_text([["", "", "", ""]]),
            csv_text([["spotify:local:a", "", "", ""]]),
        ):
            with self.assertRaises(parser.ImportError):
                parser.parse_csv(io.StringIO(text))

    def test_malformed_csv(self):
        for text in ('"unterminated', '"quoted"garbage,rest'):
            with self.assertRaisesRegex(parser.ImportError, "line 2: malformed CSV"):
                parser.parse_csv(io.StringIO(csv_text([]) + text))


class FileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "input with spaces.csv"
        self.output = self.root / "private albums.json"
        self.source.write_text(csv_text([record()]), encoding="utf-8-sig", newline="")

    def cli(self, *extra, source=None, output=None):
        return subprocess.run(
            [
                sys.executable,
                "-B",
                str(SCRIPT),
                f"--input={source or self.source}",
                f"--output={output or self.output}",
                *map(str, extra),
            ],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )

    def test_bom_spaces_success_and_private_output(self):
        result = self.cli(
            "--against", self.root / "cache", "--against", self.root / "lock"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("rows=1, albums=1", result.stderr)
        self.assertIn("blank=0, local=0, episode=0, unavailable=0", result.stderr)
        self.assertEqual(json.loads(self.output.read_text())[0]["spotify_id"], ID_A)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o600)

    def test_late_failure_preserves_bytes_mtimes_and_no_directories(self):
        self.source.write_text(
            csv_text([record(), record(artist="secret-invalid-value")]),
            encoding="utf-8",
        )
        paths = [
            self.output,
            self.root / "report",
            self.root / "cache",
            self.root / "lock",
        ]
        for path in paths:
            path.write_bytes(b"original")
        before = [(path.read_bytes(), path.stat().st_mtime_ns) for path in paths]
        arguments = [value for path in paths[1:] for value in ("--against", path)]
        for output in (self.output, self.root / "not-created" / "albums.json"):
            result = self.cli(*arguments, output=output)
            self.assertEqual(result.returncode, 1)
            self.assertIn("line 3:", result.stderr)
            self.assertNotIn("secret-invalid-value", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertEqual(
                before, [(path.read_bytes(), path.stat().st_mtime_ns) for path in paths]
            )
            self.assertFalse((self.root / "not-created").exists())

    def test_input_aliases_output_and_against(self):
        symlink = self.root / "symlink"
        symlink.symlink_to(self.source)
        hardlink = self.root / "hardlink"
        os.link(self.source, hardlink)
        original = self.source.read_bytes(), self.source.stat().st_mtime_ns
        for alias in (
            self.source,
            symlink,
            hardlink,
            self.root / "." / self.source.name,
        ):
            for args in ({"output": alias}, {}):
                extra = () if args else ("--against", alias)
                result = self.cli(*extra, **args)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("aliases", result.stderr)
                self.assertEqual(
                    original, (self.source.read_bytes(), self.source.stat().st_mtime_ns)
                )
                self.assertFalse(self.output.exists())

    def test_output_aliases_protected_path(self):
        self.output.write_bytes(b"preserve")
        link = self.root / "cache"
        os.link(self.output, link)
        symlink = self.root / "report"
        symlink.symlink_to(self.output)
        for protected in (self.output, link, symlink):
            result = self.cli("--against", protected)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(self.output.read_bytes(), b"preserve")

    def test_nonexistent_resolved_output_collision_creates_no_directories(self):
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        output = self.root / "new" / "albums.json"
        protected = alias / "new" / "albums.json"
        result = self.cli("--against", protected, output=output)
        self.assertEqual(result.returncode, 1)
        self.assertIn("aliases", result.stderr)
        self.assertFalse(output.parent.exists())

    def test_late_malformed_row_preserves_output(self):
        self.output.write_bytes(b"original")
        before = self.output.stat().st_mtime_ns
        bad_uri = record()
        bad_uri[0] = "private-malformed-uri"
        for text in (
            csv_text([record(), bad_uri]),
            csv_text([record(), record()[:-1]]),
            csv_text([record()]) + '"private-unterminated',
        ):
            self.source.write_text(text, encoding="utf-8")
            result = self.cli()
            self.assertEqual(result.returncode, 1)
            self.assertIn("line 3:", result.stderr)
            self.assertNotIn("private-", result.stderr)
            self.assertEqual(self.output.read_bytes(), b"original")
            self.assertEqual(self.output.stat().st_mtime_ns, before)

    def test_invalid_encoding(self):
        self.source.write_bytes(csv_text([]).encode() + b"\xff")
        result = self.cli()
        self.assertEqual(result.returncode, 1)
        self.assertIn("UTF-8", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.output.exists())

    def test_nonregular_or_missing_input_never_blocks(self):
        fifo = self.root / "fifo"
        os.mkfifo(fifo)
        for source in (fifo, self.root, self.root / "missing"):
            result = self.cli(source=source)
            self.assertEqual(result.returncode, 1)
            self.assertIn("exportify-csv: line 1:", result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertFalse(self.output.exists())

    def test_leading_dash_filename(self):
        source = self.root / "-input.csv"
        source.write_bytes(self.source.read_bytes())
        result = subprocess.run(
            [
                sys.executable,
                "-B",
                str(SCRIPT),
                "--input=-input.csv",
                "--output=private albums.json",
            ],
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()

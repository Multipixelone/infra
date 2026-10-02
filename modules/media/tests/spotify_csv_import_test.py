"""Offline integration tests of the COMPLETE inline production Fish importer.

Run: python3 modules/media/tests/spotify_csv_import_test.py
Uses actual CSV parser, extracted cache/inventory helpers, and destination
validation. Only beet, Qobuz provider/preflight, and evidence reporting are fake.
Requires python3, fish, jq, coreutils; no credentials or network are used.
"""

import csv
import json
import os
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "modules/media/streamrip.nix"
PARSER = ROOT / "modules/media/spotify_exportify_csv.py"
TEXT = SOURCE.read_text()
BODY = TEXT.split('writeFishBin "spotify-qobuz-albums" ', 1)[1].split("\n      '';", 1)[
    0
][2:]
ALBUM_ID = "A" * 22
TRACK_ID = "T" * 22
HEADERS = ["Track URI", "Album URI", "Album Name", "Album Artist Name(s)"]


def python_helper(binding, name):
    marker = f'{binding} = pkgs.writeText "{name}" '
    body = TEXT.split(marker, 1)[1].split("\n      '';", 1)[0][2:]
    if "${" in body or "''" in body:
        raise AssertionError("unhandled Nix escapes in Python helper")
    return textwrap.dedent(body)


FAKE = r"""
import json, os, pathlib, subprocess, sys
kind = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
def arg(name):
    for index, value in enumerate(args):
        if value == name:
            return args[index + 1]
        if value.startswith(name + '='):
            return value.split('=', 1)[1]
    raise AssertionError(name)
def write(name, value):
    pathlib.Path(arg(name)).write_text(json.dumps(value))
if kind == 'evidence' and args[0] == 'validate-destination':
    # Real, side-effect-free production alias validator.
    sys.exit(subprocess.call([sys.executable, os.environ['MATCHER'], *args]))
with open(os.environ['CALLS'], 'a') as log:
    log.write(json.dumps([kind, args]) + '\n')
if kind == 'beet':
    assert args[-4:] == ['list', '-a', '-f', '$albumartist\x1f$album\x1f$id']
    if os.environ.get('OWNED'):
        print('Artist\x1fAlbum\x1f7')
elif kind == 'rip':
    if args[0] == 'search':
        query = args[-1]
        if os.environ.get('AMBIGUOUS'):
            records = [{'source': 'qobuz', 'media_type': 'album', 'id': 'q1', 'desc': 'Different by Someone'}]
        else:
            records = [{'source': 'qobuz', 'media_type': 'album', 'id': 'q1', 'desc': query}]
        pathlib.Path(arg('--output-file')).write_text(json.dumps(records))
    else:
        assert args[0] == 'file'
        records = json.loads(pathlib.Path(args[1]).read_text())
        pathlib.Path(os.environ['DOWNLOADED']).write_text(json.dumps(records))
elif kind == 'preflight':
    if os.environ.get('PREFLIGHT_FAIL'):
        sys.exit(1)
    records = json.loads(pathlib.Path(arg('--input')).read_text())
    complete = bool(os.environ.get('COMPLETE'))
    write('--valid', records)
    write('--rejected', [])
    write('--pending', [] if complete else records)
    write('--status', [{'id': r['id'], 'artist': 'Artist', 'title': 'Album', 'complete': complete,
                        'downloaded_tracks': int(complete), 'total_tracks': 1,
                        'missing_tracks': int(not complete)} for r in records])
elif kind == 'evidence':
    assert args[0] == 'run-report'
    write('--destination', {'fixture': True})
else:
    raise AssertionError(kind)
"""


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="spotify csv integration ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.calls = self.root / "calls.jsonl"
        self.output = self.root / "albums.json"
        self.cache = self.root / "state" / "matches.json"
        self.input = self.root / "playlist export.csv"
        self.downloaded = self.root / "downloaded.json"
        self.write_csv()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("SPOTIFY_")}
        self.env.update(
            CALLS=str(self.calls),
            DOWNLOADED=str(self.downloaded),
            MATCHER=str(ROOT / "pkgs/openclaw-music/openclaw_music/qobuz_matcher.py"),
            TMPDIR=str(self.root),
            HOME=str(self.root),
        )
        self.executables = {}
        for kind in ("beet", "rip", "preflight", "evidence"):
            self.executables[kind] = self.executable(
                kind, "#!/usr/bin/env python3\n" + FAKE
            )
        for binding, name, kind in (
            (
                "spotify-qobuz-match-cache-script",
                "spotify-qobuz-match-cache.py",
                "cache",
            ),
            (
                "beets-library-inventory-script",
                "beets-library-inventory.py",
                "inventory",
            ),
        ):
            self.executables[kind] = self.executable(
                kind, "#!" + sys.executable + "\n" + python_helper(binding, name)
            )
        self.executables["csv"] = self.executable(
            "csv",
            "#!/usr/bin/env python3\nimport os, sys\nos.execv(sys.executable, [sys.executable, "
            + repr(str(PARSER))
            + ", *sys.argv[1:]])\n",
        )
        self.script = self.root / "spotify-qobuz-albums.fish"
        self.script.write_text(self.render())

    def executable(self, name, body):
        path = self.root / name
        path.write_text(body)
        path.chmod(0o700)
        return path

    def render(self):
        replacements = {
            "${lib.getExe spotify-exportify-csv}": self.executables["csv"],
            "${lib.getExe pkgs.jq}": shutil.which("jq"),
            "${lib.getExe pkgs.streamrip}": self.executables["rip"],
            "${lib.getExe streamrip-qobuz-preflight}": self.executables["preflight"],
            "${lib.getExe spotify-qobuz-match-cache}": self.executables["cache"],
            "${lib.getExe spotify-qobuz-match-evidence}": self.executables["evidence"],
            "${lib.getExe beets-library-inventory}": self.executables["inventory"],
            "${lib.getExe inputs.beets-plugins.packages.${pkgs.stdenv.hostPlatform.system}.default}": self.executables[
                "beet"
            ],
            '${lib.escapeShellArg "${config.xdg.configHome}/streamrip/config.toml"}': self.root
            / "config.toml",
            '${lib.escapeShellArg "${config.xdg.stateHome}/spotify-qobuz-albums/matches.json"}': self.cache,
        }
        for command in ("mktemp", "chmod", "rm", "mv"):
            replacements["${lib.getExe' pkgs.coreutils \"" + command + '"}'] = (
                shutil.which(command)
            )
        rendered = BODY
        for marker, path in replacements.items():
            self.assertIn(marker, rendered, f"stale extraction substitution: {marker}")
            rendered = rendered.replace(marker, shlex.quote(str(path)))
        self.assertNotIn(
            "${", rendered, "unknown Nix interpolation: update explicit substitutions"
        )
        return rendered

    def write_csv(self, name="Album", artist="Artist", late_invalid=False):
        with self.input.open("w", encoding="utf-8-sig", newline="") as output:
            writer = csv.writer(output)
            writer.writerow(HEADERS)
            writer.writerow(
                [f"spotify:track:{TRACK_ID}", f"spotify:album:{ALBUM_ID}", name, artist]
            )
            if late_invalid:
                writer.writerow(
                    ["spotify:track:bad", f"spotify:album:{ALBUM_ID}", name, artist]
                )

    def run_import(self, flags=(), env=None, input_path=None):
        result = subprocess.run(
            [
                "fish",
                "--no-config",
                str(self.script),
                "--output",
                str(self.output),
                "--match-cache",
                str(self.cache),
                *flags,
                "--",
                str(input_path or self.input),
            ],
            cwd=self.root,
            env={**self.env, **(env or {})},
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
        self.assertFalse(
            list(self.root.glob(".spotify-qobuz-albums*")), "publication temps leaked"
        )
        self.assertFalse(
            [p for p in self.root.glob("tmp.*") if p.is_dir()], "private temps leaked"
        )
        return result

    def logged(self, kind=None):
        rows = (
            [json.loads(line) for line in self.calls.read_text().splitlines()]
            if self.calls.exists()
            else []
        )
        return [row for row in rows if kind is None or row[0] == kind]

    def snapshots(self):
        paths = [self.output, self.cache, Path(str(self.cache) + ".lock")]
        paths.extend(
            self.root / ("albums." + suffix + ".json")
            for suffix in ("rejected", "status", "unmatched", "beets", "match-evidence")
        )
        return {
            p: (p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_ino)
            for p in paths
            if p.exists()
        }

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_valid_no_auth_atomic_private_publication_and_multiline(self):
        self.write_csv(
            name='Quoted "Album"\nSecond line', artist="Artist One; Artist Two\nThird"
        )
        self.output.write_text("[]\n")
        old_inode = self.output.stat().st_ino
        result = self.run_import(["--no-download"])
        self.assert_success(result)
        self.assertEqual(
            json.loads(self.output.read_text()),
            [{"source": "qobuz", "media_type": "album", "id": "q1"}],
        )
        self.assertNotEqual(old_inode, self.output.stat().st_ino)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        query = self.logged("rip")[0][1][-1]
        self.assertEqual(
            query, 'Quoted "Album"\nSecond line by Artist One; Artist Two\nThird'
        )
        self.assertIn('Quoted "Album" Second line', result.stdout)
        self.assertEqual(len(self.logged("beet")), 1)
        self.assertEqual(len(self.logged("preflight")), 1)
        self.assertFalse(self.downloaded.exists())
        for forbidden in (
            "SPOTIFY_ACCESS_TOKEN",
            "SPOTIFY_REFRESH_TOKEN",
            "beets-harmony",
            "api.spotify.com",
            "accounts.spotify.com",
            "$curl",
            "pkgs.curl",
        ):
            self.assertNotIn(forbidden, BODY)

    def test_late_invalid_preserves_all_existing_state(self):
        self.assert_success(self.run_import(["--no-download"]))
        before = self.snapshots()
        self.calls.unlink()
        self.write_csv(late_invalid=True)
        result = self.run_import(["--refresh-matches", "--yes"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(before, self.snapshots())
        self.assertEqual(self.logged(), [])

    def test_late_invalid_creates_no_persistent_state(self):
        self.write_csv(late_invalid=True)
        result = self.run_import(["--yes"])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.cache.parent.exists())
        self.assertEqual(self.snapshots(), {})
        self.assertEqual(self.logged(), [])

    def test_owned_skips_all_qobuz_work(self):
        self.assert_success(
            self.run_import(["--yes", "--retry-existing"], {"OWNED": "1"})
        )
        self.assertEqual(self.logged("rip"), [])
        self.assertEqual(self.logged("preflight"), [])
        self.assertFalse(self.output.exists())
        self.assertEqual(
            len(json.loads((self.root / "albums.beets.json").read_text())), 1
        )

    def test_cached_match_and_refresh(self):
        self.assert_success(self.run_import(["--no-download"]))
        self.calls.unlink()
        result = self.run_import(["--no-download"])
        self.assert_success(result)
        self.assertEqual(self.logged("rip"), [])
        self.assertIn("cached matches reused: 1", result.stdout)
        self.calls.unlink()
        self.assert_success(self.run_import(["--refresh-matches", "--no-download"]))
        self.assertEqual(len(self.logged("rip")), 1)

    def test_cached_skip_and_refresh(self):
        self.assert_success(self.run_import(["--no-download"]))
        record = {
            "spotify_id": ALBUM_ID,
            "name": "Album",
            "artist": "Artist",
            "spotify_url": f"https://open.spotify.com/album/{ALBUM_ID}",
        }
        subprocess.run(
            [
                str(self.executables["cache"]),
                "set",
                "--cache",
                str(self.cache),
                "--spotify",
                json.dumps(record),
                "--action",
                "skip",
                "--selection",
                "manual",
            ],
            check=True,
            capture_output=True,
        )
        self.calls.unlink()
        result = self.run_import(["--no-download"])
        self.assertNotEqual(
            result.returncode, 0
        )  # Existing no-resolved-albums contract.
        self.assertIn("cached skips reused: 1", result.stdout)
        self.assertEqual(self.logged("rip"), [])
        self.assertEqual(
            json.loads((self.root / "albums.unmatched.json").read_text())[0]["reason"],
            "cached_selection_skipped",
        )
        self.calls.unlink()
        self.assert_success(self.run_import(["--refresh-matches", "--no-download"]))
        self.assertEqual(len(self.logged("rip")), 1)

    def test_no_download_yes_retry_existing_and_noninteractive_safety(self):
        self.assert_success(self.run_import(["--no-download", "--yes"]))
        self.assertFalse(self.downloaded.exists())
        self.assert_success(self.run_import(["--yes"], {"COMPLETE": "1"}))
        self.assertFalse(self.downloaded.exists())
        self.assert_success(
            self.run_import(
                ["--retry-existing", "--no-download", "--yes"], {"COMPLETE": "1"}
            )
        )
        self.assertFalse(self.downloaded.exists())
        self.assert_success(
            self.run_import(["--retry-existing", "--yes"], {"COMPLETE": "1"})
        )
        self.assertEqual(json.loads(self.downloaded.read_text())[0]["id"], "q1")
        self.downloaded.unlink()
        result = self.run_import()
        self.assert_success(result)
        self.assertIn("not downloading without a TTY", result.stderr)
        self.assertFalse(self.downloaded.exists())

    def test_preflight_failure_preserves_primary_and_rejected_manifests(self):
        self.assert_success(self.run_import(["--no-download"]))
        before = {
            p: (p.read_bytes(), p.stat().st_mtime_ns)
            for p in (self.output, self.root / "albums.rejected.json")
        }
        result = self.run_import(["--yes"], {"PREFLIGHT_FAIL": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("preflight failed", result.stderr)
        self.assertEqual(
            before, {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in before}
        )
        self.assertFalse(self.downloaded.exists())

    def test_yes_does_not_override_ambiguous_selection_safety(self):
        result = self.run_import(["--yes"], {"AMBIGUOUS": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires confirmation without a TTY", result.stderr)
        self.assertEqual(self.logged("preflight"), [])
        self.assertFalse(self.downloaded.exists())
        self.assertFalse(self.output.exists())
        self.assertEqual(
            json.loads((self.root / "albums.unmatched.json").read_text())[0]["reason"],
            "ambiguous_noninteractive",
        )

    def test_invalid_existing_manifest_does_not_initialize_cache(self):
        self.output.write_text('{"wrong": "schema"}\n')
        before = self.snapshots()
        result = self.run_import(["--yes"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("existing output manifest is invalid", result.stderr)
        self.assertEqual(before, self.snapshots())
        self.assertFalse(self.cache.parent.exists())
        self.assertEqual(self.logged(), [])

    def test_leading_dash_path_and_url_rejection(self):
        leading = self.root / "-playlist.csv"
        self.input.rename(leading)
        self.assert_success(
            self.run_import(["--no-download"], input_path="-playlist.csv")
        )
        self.calls.unlink()
        before = self.snapshots()
        result = self.run_import(input_path="https://open.spotify.com/playlist/example")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("URLs are no longer supported", result.stderr)
        self.assertEqual(before, self.snapshots())
        self.assertEqual(self.logged(), [])

    def test_csv_aliases_all_mutable_paths_rejected(self):
        paths = [self.output, self.cache, Path(str(self.cache) + ".lock")]
        paths.extend(
            self.root / ("albums." + suffix + ".json")
            for suffix in ("rejected", "status", "unmatched", "beets", "match-evidence")
        )
        for path in paths:
            for mode in ("symlink", "hardlink"):
                with self.subTest(path=path.name, mode=mode):
                    path.parent.mkdir(parents=True, exist_ok=True)
                    if mode == "symlink":
                        path.symlink_to(self.input)
                    else:
                        os.link(self.input, path)
                    before = self.snapshots()
                    result = self.run_import(["--yes"])
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(before, self.snapshots())
                    self.assertEqual(self.logged(), [])
                    path.unlink()

    def test_mutable_destinations_alias_rejected_before_cache_init(self):
        self.cache.parent.mkdir()
        self.output.write_text("[]\n")
        self.cache.symlink_to(self.output)
        before = self.snapshots()
        result = self.run_import(["--yes"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("destinations alias", result.stderr)
        self.assertEqual(before, self.snapshots())
        self.assertFalse(Path(str(self.cache) + ".lock").exists())
        self.assertEqual(self.logged(), [])

    def test_help_and_full_fish_syntax(self):
        result = subprocess.run(
            ["fish", "--no-config", "--no-execute", str(self.script)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assert_success(result)
        result = subprocess.run(
            ["fish", "--no-config", str(self.script), "--help"],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assert_success(result)
        self.assertIn("EXPORTIFY.csv", result.stdout)
        self.assertIn("not offline", result.stdout)
        self.assertFalse(self.cache.parent.exists())
        self.assertEqual(self.logged(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)

"""Bounded API fixtures and throwaway beets albums; no live history or tags."""

import fcntl
import io
import json
import sqlite3
import unittest
from argparse import Namespace
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlsplit

from beets.library import Item
from listen_queue.cli import parser
from listen_queue.errors import ListenError
from listen_queue.first_played import Cache, api_key, backfill, fetch_page, parse_page
from test_cli import LibraryCase


def scrobble(artist="Artist", album="One", stamp=1000, mbid=""):
    return {
        "artist": {"#text": artist, "mbid": "artist-id"},
        "album": {"#text": album, "mbid": mbid},
        "mbid": "track-id",
        "date": {"uts": str(stamp)},
    }


def page(tracks, number=1, total=1):
    return json.dumps(
        {
            "recenttracks": {
                "@attr": {
                    "page": str(number),
                    "totalPages": str((total + 199) // 200),
                    "total": str(total),
                    "user": "Tunnelmaker",
                },
                "track": tracks,
            }
        }
    ).encode()


class Clock:
    def __init__(self):
        self.now = 10000.0
        self.sleeps = []

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds


class BackfillTests(LibraryCase):
    def setUp(self):
        super().setUp()
        self.credentials = self.root / "lastfm"
        self.credentials.write_text(
            "export API_KEY='fixture-secret'\nAPI_SECRET='unused'\n"
        )
        self.cache = self.root / "cache"
        self.args = Namespace(
            apply=False,
            dry_run=True,
            cache_dir=self.cache,
            credentials_file=self.credentials,
        )
        self.clock = Clock()
        self.requests = []
        self.responses = [page([scrobble()])]
        self.config_patch = patch.dict("os.environ", self.env)
        self.config_patch.start()
        self.addCleanup(self.config_patch.stop)

    def request(self, request, timeout):
        self.requests.append((request, timeout, self.clock.time()))
        value = self.responses.pop(0)
        if isinstance(value, Exception):
            raise value
        return io.BytesIO(value)

    def run_backfill(self):
        output = io.StringIO()
        with (
            patch("listen_queue.first_played.urlopen", side_effect=self.request),
            patch("listen_queue.first_played.time.time", side_effect=self.clock.time),
            patch(
                "listen_queue.first_played.time.monotonic", side_effect=self.clock.time
            ),
            patch("listen_queue.first_played.time.sleep", side_effect=self.clock.sleep),
            patch.object(Item, "write", side_effect=AssertionError("no tags")),
            patch.object(Item, "try_write", side_effect=AssertionError("no tags")),
            redirect_stderr(output),
        ):
            result = backfill(
                self.args, self.config, self.root / "state", self.root / ".import.lock"
            )
        self.output = output.getvalue()
        return result

    def db_dump(self):
        with sqlite3.connect(self.root / "library.db") as conn:
            return list(conn.iterdump())

    def dates(self):
        with sqlite3.connect(self.root / "library.db") as conn:
            return dict(
                conn.execute(
                    "SELECT entity_id, value FROM album_attributes WHERE key='lastfm_first_played'"
                )
            )

    def test_cutoff_pagination_dry_run_and_zero_request_apply(self):
        first, second = self.create(
            {"album": "One", "added": 2000}, {"album": "Two", "added": 3000}
        )
        self.responses = [
            page([scrobble(stamp=1900)] * 200, total=201),
            page([scrobble(stamp=1000)], number=2, total=201),
        ]
        before = self.db_dump()
        media = {
            path: (path.read_bytes(), path.stat().st_mtime_ns)
            for path in (self.root / "music").iterdir()
        }
        library_bytes = (self.root / "library.db").read_bytes()
        result = self.run_backfill()
        self.assertEqual(result["pages"], 2)
        self.assertEqual(result["scrobbles"], 201)
        self.assertEqual(result["planned_updates"], 1)
        self.assertFalse(result["applied"])
        self.assertEqual(before, self.db_dump())
        self.assertEqual(library_bytes, (self.root / "library.db").read_bytes())
        self.assertIn("estimated pages: 2", self.output)
        for index, (request, timeout, started) in enumerate(self.requests):
            params = parse_qs(urlsplit(request.full_url).query)
            self.assertEqual(params["to"], ["2000"])
            self.assertEqual(params["limit"], ["200"])
            self.assertEqual(params["page"], [str(index + 1)])
            self.assertEqual(params["method"], ["user.getRecentTracks"])
            self.assertEqual(params["user"], ["Tunnelmaker"])
            self.assertNotIn("from", params)
            self.assertIn("first-played", request.get_header("User-agent"))
            self.assertEqual(timeout, 30)
        self.assertGreaterEqual(self.requests[1][2] - self.requests[0][2], 1)
        self.assertEqual(
            json.loads((self.cache / "checkpoint.json").read_text())["next_page"], 3
        )
        for path in self.cache.iterdir():
            self.assertNotIn(b"fixture-secret", path.read_bytes())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o700)
        self.args.apply = True
        self.credentials.unlink()
        self.run_backfill()
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(self.dates(), {first: "1000"})
        after = [line for line in self.db_dump() if "'lastfm_first_played'" not in line]
        self.assertEqual(before, after)
        self.assertEqual(
            media,
            {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in media},
        )
        self.assertNotIn(second, self.dates())
        self.assertEqual(self.run_backfill()["planned_updates"], 0)
        cli = self.invoke(
            "backfill-first-played", "--cache-dir", self.cache, "--dry-run"
        )
        self.assertEqual(cli["cached_pages"], 2)
        self.assertEqual(cli["fetched_pages"], 0)

    def test_interrupted_scan_resumes_missing_page_only(self):
        (album,) = self.create({"album": "One", "added": 2000})
        self.args.apply = True
        self.responses = [
            page([scrobble(stamp=1900)] * 200, total=201),
            HTTPError("SECRET-URL", 403, "secret", {}, None),
        ]
        with self.assertRaises(ListenError) as caught:
            self.run_backfill()
        self.assertNotIn("SECRET", str(caught.exception))
        self.assertEqual(self.dates(), {})
        self.assertEqual(
            json.loads((self.cache / "checkpoint.json").read_text())["next_page"], 2
        )
        self.responses = [page([scrobble(stamp=1000)], number=2, total=201)]
        result = self.run_backfill()
        self.assertEqual(len(self.requests), 3)
        self.assertEqual(result["cached_pages"], 1)
        self.assertEqual(self.dates(), {album: "1000"})

    def test_matching_ids_names_all_editions_and_unmatched_report(self):
        release, group, name, duplicate, compilation = self.create(
            {"album": "Renamed", "identifiers": {"mb_albumid": "release-id"}},
            {"album": "Group", "identifiers": {"mb_releasegroupid": "group-id"}},
            {"artist": "Björk", "album": "  Álbum  "},
            {"artist": "Bjork", "album": "Album"},
            {"artist": "Track Artist", "album": "Compilation"},
        )
        with sqlite3.connect(self.root / "library.db") as conn:
            conn.execute(
                "UPDATE albums SET albumartist='Various Artists' WHERE id=?",
                (compilation,),
            )
        tracks = [
            scrobble(album="Different", mbid="RELEASE-ID"),
            scrobble(album="Different", mbid="GROUP-ID"),
            scrobble(artist="BJORK", album="album", stamp=700),
            scrobble(artist="Track Artist", album="Compilation"),
            scrobble(album="Unknown", stamp=500),
            scrobble(album="Unknown", stamp=900),
        ]
        self.responses = [page(tracks, total=len(tracks))]
        self.args.apply = True
        result = self.run_backfill()
        self.assertEqual(
            set(self.dates()), {release, group, name, duplicate, compilation}
        )
        self.assertEqual(self.dates()[name], "700")
        self.assertEqual(result["unmatched_albums"], 1)
        self.assertEqual(
            result["unmatched_sample"],
            [{"artist": "Artist", "album": "Unknown", "first_played": 500}],
        )
        self.assertEqual(
            result["matching_methods"],
            {"release": 1, "release_group": 1, "artist_album": 2, "unmatched": 2},
        )

    def test_existing_and_concurrent_earlier_dates_win(self):
        (album,) = self.create({"album": "One", "added": 2000})
        self.run_backfill()
        with sqlite3.connect(self.root / "library.db") as conn:
            conn.execute(
                "INSERT INTO album_attributes(entity_id, key, value) VALUES (?, 'lastfm_first_played', '500')",
                (album,),
            )
        self.args.apply = True
        result = self.run_backfill()
        self.assertEqual(result["planned_updates"], 0)
        self.assertEqual(self.dates(), {album: "500"})

    def test_date_written_during_network_scan_is_reloaded_before_apply(self):
        (album,) = self.create({"album": "One", "added": 2000})
        original = self.request

        def concurrent(request, timeout):
            with sqlite3.connect(self.root / "library.db") as conn:
                conn.execute(
                    "INSERT INTO album_attributes(entity_id, key, value) VALUES (?, 'lastfm_first_played', '500')",
                    (album,),
                )
            return original(request, timeout)

        self.request = concurrent
        self.args.apply = True
        self.assertEqual(self.run_backfill()["planned_updates"], 0)
        self.assertEqual(self.dates(), {album: "500"})

    def test_no_import_lock_during_scan_but_apply_requires_it(self):
        self.create({"album": "One"})
        with (self.root / ".import.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertFalse(self.run_backfill()["applied"])
            self.args.apply = True
            with (
                patch.dict("os.environ", {"LISTEN_BEETS_LOCK_TIMEOUT": "0"}),
                self.assertRaises(ListenError) as caught,
            ):
                self.run_backfill()
            self.assertEqual(caught.exception.exit_code, 75)
            self.assertEqual(self.dates(), {})

    def test_cutoff_change_or_corrupt_cache_fails_without_requests(self):
        self.create({"album": "One", "added": 2000})
        self.run_backfill()
        path = self.cache / "page-000001.json"
        original = path.read_bytes()
        path.write_text("broken")
        with self.assertRaises(ListenError):
            self.run_backfill()
        path.write_bytes(original)
        with sqlite3.connect(self.root / "library.db") as conn:
            conn.execute("UPDATE albums SET added=1500")
        with self.assertRaises(ListenError):
            self.run_backfill()
        self.assertEqual(len(self.requests), 1)

    def test_empty_history_and_invalid_library_date(self):
        self.create({"album": "One", "added": 2000})
        self.responses = [page([], total=0)]
        self.assertEqual(self.run_backfill()["planned_updates"], 0)
        with sqlite3.connect(self.root / "library.db") as conn:
            conn.execute("UPDATE albums SET added=0")
        with self.assertRaises(ListenError):
            self.run_backfill()
        self.assertEqual(len(self.requests), 1)

    def test_invalid_response_is_cached_and_never_refetched(self):
        self.create({"album": "One", "added": 2000})
        self.responses = [page([scrobble(stamp=2001)])]
        for _ in range(2):
            with self.assertRaises(ListenError):
                self.run_backfill()
        self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.dates(), {})

    def test_missing_completed_page_is_a_cache_error(self):
        self.create({"album": "One", "added": 2000})
        self.run_backfill()
        (self.cache / "page-000001.json").unlink()
        with self.assertRaises(ListenError):
            self.run_backfill()
        self.assertEqual(len(self.requests), 1)


class ProtocolTests(unittest.TestCase):
    def test_cli_defaults_and_exclusive_modes(self):
        self.assertFalse(parser().parse_args(["backfill-first-played"]).apply)
        with self.assertRaises(ListenError):
            parser().parse_args(["backfill-first-played", "--apply", "--dry-run"])

    def test_nowplaying_and_bound_validation(self):
        now = scrobble(stamp=9999)
        now["@attr"] = {"nowplaying": "true"}
        self.assertEqual(len(parse_page(page([now]), 1, 2000)[0]), 1)
        with self.assertRaises(ListenError):
            parse_page(page([scrobble(stamp=2001)]), 1, 2000)
        self.assertEqual(len(parse_page(page(scrobble(stamp=2000)), 1, 2000)[0]), 1)

    def test_throttle_exponential_backoff_retry_after_and_safe_errors(self):
        clock = Clock()
        cache = Cache.__new__(Cache)
        cache.state = {"cutoff": 2000, "last_request": 0}
        cache.save = lambda: None
        responses = [
            HTTPError("SECRET", 429, "SECRET", {"Retry-After": "3"}, None),
            HTTPError("SECRET", 503, "SECRET", {}, None),
            URLError("SECRET"),
            io.BytesIO(page([scrobble()])),
        ]
        with (
            patch(
                "listen_queue.first_played.urlopen", side_effect=responses
            ) as request,
            patch("listen_queue.first_played.time.time", side_effect=clock.time),
            patch("listen_queue.first_played.time.monotonic", side_effect=clock.time),
            patch("listen_queue.first_played.time.sleep", side_effect=clock.sleep),
        ):
            fetch_page(cache, 1, "fixture-secret")
        self.assertEqual(clock.sleeps, [3, 2, 4])
        self.assertEqual(request.call_count, 4)
        for call in request.call_args_list:
            self.assertEqual(
                parse_qs(urlsplit(call.args[0].full_url).query)["to"], ["2000"]
            )
        with (
            patch(
                "listen_queue.first_played.urlopen",
                side_effect=HTTPError("SECRET", 401, "SECRET", {}, None),
            ),
            patch.object(cache, "request_started"),
            self.assertRaises(ListenError) as caught,
        ):
            fetch_page(cache, 1, "fixture-secret")
        self.assertNotIn("SECRET", str(caught.exception))

    def test_throttle_survives_wall_clock_jump_and_process_resume(self):
        clock = Clock()
        cache = Cache.__new__(Cache)
        cache.state = {"last_request": clock.time()}
        cache.save = lambda: None
        with (
            patch("listen_queue.first_played.time.time", side_effect=clock.time),
            patch("listen_queue.first_played.time.monotonic", side_effect=clock.time),
            patch("listen_queue.first_played.time.sleep", side_effect=clock.sleep),
        ):
            cache.request_started()
        self.assertEqual(clock.sleeps, [1])
        with (
            patch(
                "listen_queue.first_played.time.time", return_value=clock.time() + 100
            ),
            patch(
                "listen_queue.first_played.time.monotonic",
                return_value=cache.last_attempt,
            ),
            patch("listen_queue.first_played.time.sleep") as sleep,
        ):
            cache.request_started()
        sleep.assert_called_once_with(1)

    def test_credential_assignments_are_not_executed(self):
        import tempfile

        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "secret"
            marker = Path(root) / "executed"
            path.write_text(
                f"API_SECRET='ignore'\nexport API_KEY='safe-key' # comment\ntouch {marker}\n"
            )
            self.assertEqual(api_key(path), "safe-key")
            self.assertFalse(marker.exists())
            path.write_text(f"API_KEY=$(touch {marker})\n")
            with self.assertRaises(ListenError):
                api_key(path)
            self.assertFalse(marker.exists())

"""Last.fm ranking reads only throwaway libraries and private fixtures."""

import unittest
from contextlib import redirect_stdout
from io import StringIO
from types import SimpleNamespace

from listen_queue.cli import human
from listen_queue.library import Queue, play_count
from test_cli import LibraryCase


def item(**fields):
    return SimpleNamespace(
        get=lambda key, default=None, **kwargs: fields.get(key, default)
    )


class PlayCountTests(unittest.TestCase):
    def test_missing_invalid_and_legacy_counts(self):
        for value in (None, "", "bad", -1, 1.5, "nan", "inf", True, False, 10**400):
            with self.subTest(value=value):
                self.assertEqual(play_count(item(play_count=value)), 0)
                self.assertEqual(
                    play_count(item(lastfm_play_count=value, play_count="7")), 7
                )
        self.assertEqual(play_count(item()), 0)
        for value in (0, 3, "3", "3.0"):
            with self.subTest(value=value):
                self.assertEqual(play_count(item(play_count=value)), int(float(value)))

    def test_modern_zero_and_counts_override_legacy(self):
        self.assertEqual(play_count(item(lastfm_play_count=0, play_count=99)), 0)
        self.assertEqual(play_count(item(lastfm_play_count="4", play_count=99)), 4)

    def test_empty_album_has_no_average(self):
        album = SimpleNamespace(
            id=1,
            albumartist="Artist",
            album="Empty",
            year=0,
            label="",
            added=0,
            items=list,
            get=lambda key, default=None: default,
        )
        queue = Queue.__new__(Queue)
        queue.fields = {}
        metadata = queue.metadata(album)
        self.assertEqual(metadata["play_count"], 0)
        self.assertEqual(metadata["track_count"], 0)
        self.assertIsNone(metadata["plays_per_track"])


class RankingTests(LibraryCase):
    def test_sum_normalization_sort_and_state_independence(self):
        low, high, unmarked, dropped, missing = self.create(
            {"album": "Low", "state": "listened", "scores": {"play_count": [2]}},
            {
                "album": "High",
                "state": "queued",
                "lengths": [60] * 3,
                "scores": {
                    "lastfm_play_count": [4, None, 0],
                    "play_count": [99, 3, 99],
                },
            },
            {"album": "Unmarked", "scores": {"play_count": [5]}},
            {"album": "Dropped", "state": "dropped", "scores": {"play_count": [1]}},
            {"album": "Missing", "state": "listened"},
        )
        before = (self.root / "library.db").read_bytes()
        data = self.invoke("most-played")
        self.assertEqual(data["basis"], "played")
        self.assertEqual(
            [a["id"] for a in data["albums"]], [high, unmarked, low, dropped]
        )
        self.assertEqual(data["albums"][0]["play_count"], 7)
        self.assertAlmostEqual(data["albums"][0]["plays_per_track"], 7 / 3)
        data = self.invoke("--json", "most-played", "--listened-only")
        self.assertEqual(data["basis"], "listened")
        self.assertEqual([a["id"] for a in data["albums"]], [low, missing])
        self.assertEqual(data["albums"][1]["play_count"], 0)
        self.assertEqual(data["albums"][1]["plays_per_track"], 0)
        self.assertEqual((self.root / "library.db").read_bytes(), before)
        self.assertFalse((self.root / "state").exists())
        rendered = StringIO()
        with redirect_stdout(rendered):
            human("most-played", data)
        self.assertIn("2 plays; 2.00 per track", rendered.getvalue())

    def test_ties_are_normalized_artist_title_then_id(self):
        later, title_later, first, duplicate, artist_later = self.create(
            {"artist": "B", "album": "First", "scores": {"play_count": [3]}},
            {"artist": "Á", "album": "Z", "scores": {"play_count": [3]}},
            {"artist": "A", "album": "Óne", "scores": {"play_count": [3]}},
            {"artist": "á", "album": "one", "scores": {"play_count": [3]}},
            {"artist": "C", "album": "First", "scores": {"play_count": [3]}},
        )
        self.assertEqual(
            [a["id"] for a in self.invoke("most-played")["albums"]],
            [first, duplicate, title_later, later, artist_later],
        )

    def test_no_plays_and_invalid_counts(self):
        self.create(
            {"album": "Missing"},
            {"album": "Zero", "scores": {"play_count": [0]}},
            {
                "album": "Invalid",
                "lengths": [60] * 5,
                "scores": {"play_count": [None, -1, "bad", "nan", 1.5]},
            },
        )
        self.assertEqual(self.invoke("most-played")["albums"], [])
        self.assertEqual(self.invoke("most-played", "--listened-only")["albums"], [])
        self.invoke("most-played", "--count", 1, exit_code=64)

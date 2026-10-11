"""Public bookmark contract and derived dates, without live library inputs."""

import copy
import importlib.util
import sys
import unittest
from pathlib import Path

SOURCE, DATA, SCHEMA = (Path(sys.argv.pop(1)) for _ in range(3))
spec = importlib.util.spec_from_file_location("life_events", SOURCE)
life_events = importlib.util.module_from_spec(spec)
spec.loader.exec_module(life_events)


class AlbumGraphBookmarksTest(unittest.TestCase):
    def setUp(self):
        self.events = life_events.load_events(DATA, SCHEMA)

    def test_exact_public_contract_and_private_notes(self):
        self.events[0]["note"] = "private note on a public event"
        self.events[-1]["note"] = "private note on a private event"
        self.events[0]["end_date"] = "2022-04-15"
        graph = {"schema_version": 3, "albums": [], "summary": {"unchanged": 7}}
        original = copy.deepcopy(graph)
        events_before = copy.deepcopy(self.events)
        enriched = life_events.add_bookmarks(graph, self.events)
        self.assertEqual(graph, original)
        self.assertEqual(self.events, events_before)
        self.assertEqual(
            {key: value for key, value in enriched.items() if key != "bookmarks"},
            original,
        )
        bookmarks = enriched["bookmarks"]
        self.assertEqual(len(bookmarks), 8)
        self.assertEqual(
            bookmarks[0],
            {
                "id": "first-visit-to-new-york",
                "date": "2022-04-12",
                "end_date": "2022-04-15",
                "precision": "day",
                "title": "First visit to New York",
                "category": "travel",
            },
        )
        for bookmark in bookmarks:
            self.assertEqual(
                set(bookmark),
                {
                    "id",
                    "date",
                    "end_date",
                    "precision",
                    "title",
                    "category",
                },
            )
        by_id = {e["id"]: e for e in bookmarks}
        self.assertNotIn("sober-date", by_id)
        self.assertEqual(by_id["met-ciara"]["category"], "friend")
        self.assertEqual(by_id["met-ciara"]["precision"], "approximate")
        self.assertIsNone(by_id["met-ciara"]["end_date"])

    def test_private_sober_date_only_appears_after_explicit_public_change(self):
        private = life_events.add_bookmarks({"albums": []}, self.events)
        self.assertNotIn("sober-date", {e["id"] for e in private["bookmarks"]})
        self.events[-1]["visibility"] = "public"
        public = life_events.add_bookmarks({"albums": []}, self.events)
        bookmark = next(e for e in public["bookmarks"] if e["id"] == "sober-date")
        self.assertEqual(bookmark["date"], "2024-08-21")
        self.assertEqual(bookmark["category"], "health")

    def test_earliest_exported_timestamp_in_utc(self):
        albums = [
            {"id": 1, "added": "2024-01-01T00:00:00Z"},
            {"id": 2, "added": "2020-12-31T23:30:00-02:00"},
            {"id": 3, "added": "2021-01-01T00:30:00.123456Z"},
            {"id": 4, "added": "2021-01-01T01:00:00+02:00"},
        ]
        graph = {"albums": albums, "library": {"earliest_added": "1990-01-01"}}
        bookmarks = life_events.add_bookmarks(graph, self.events)["bookmarks"]
        derived = next(e for e in bookmarks if e["id"] == "beets-library-import")
        self.assertEqual(
            derived,
            {
                "id": "beets-library-import",
                "date": "2020-12-31",
                "end_date": None,
                "precision": "day",
                "title": "Library imported into beets",
                "category": "music",
            },
        )
        self.assertEqual(len(bookmarks), 9)

    def test_undated_and_invalid_albums_do_not_invent_an_import_date(self):
        invalid = [
            None,
            "",
            "garbage",
            123,
            "2023-02-29T00:00:00Z",
            "2022-02-30T12:00:00Z",
            "2022-01-01T00:00:00",
            "2022-01-01",
            "0001-01-01T00:00:00+02:00",
        ]
        for albums in ([], [{}], [{"added": value} for value in invalid]):
            with self.subTest(albums=albums):
                bookmarks = life_events.add_bookmarks({"albums": albums}, [])[
                    "bookmarks"
                ]
                self.assertEqual(bookmarks, [])
        mixed = [{"added": value} for value in invalid] + [
            {"added": "2022-01-01T00:00:00Z"}
        ]
        bookmarks = life_events.add_bookmarks({"albums": mixed}, [])["bookmarks"]
        self.assertEqual(bookmarks[0]["date"], "2022-01-01")

    def test_order_is_deterministic_for_same_day_events(self):
        graph = {"albums": [{"added": "2022-09-05T00:00:00Z"}]}
        bookmarks = life_events.add_bookmarks(graph, self.events)["bookmarks"]
        reversed_order = life_events.add_bookmarks(graph, self.events[::-1])[
            "bookmarks"
        ]
        self.assertEqual(bookmarks, reversed_order)
        same_day = [e["id"] for e in bookmarks if e["date"] == "2022-09-05"]
        self.assertEqual(
            same_day, ["beets-library-import", "freshman-year-move-in", "met-ciara"]
        )


if __name__ == "__main__":
    unittest.main()

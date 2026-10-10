"""Validate real seed data and reject unsafe or inconsistent event files."""

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from jsonschema import ValidationError

SOURCE, DATA, SCHEMA, TOOL = (Path(sys.argv.pop(1)) for _ in range(4))
spec = importlib.util.spec_from_file_location("life_events", SOURCE)
life_events = importlib.util.module_from_spec(spec)
spec.loader.exec_module(life_events)


class LifeEventsDataTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.data = Path(temporary.name) / "events.json"
        self.event = {
            "id": "synthetic-event",
            "date": "2022-09-05",
            "precision": "day",
            "title": "Synthetic event",
            "category": "other",
            "visibility": "private",
        }

    def load(self, events):
        self.data.write_text(json.dumps(events), encoding="utf-8")
        return life_events.load_events(self.data, SCHEMA)

    def test_seed_matches_requested_events(self):
        events = life_events.load_events(DATA, SCHEMA)
        self.assertEqual(
            [
                (e["date"], e["title"], e["category"], e["precision"], e["visibility"])
                for e in events
            ],
            [
                ("2022-04-12", "First visit to New York", "travel", "day", "public"),
                ("2022-09-05", "Freshman year move-in", "move", "day", "public"),
                ("2022-09-05", "Met Ciara", "relationship", "approximate", "public"),
                (
                    "2022-10-21",
                    "King Gizzard & the Lizard Wizard with Ciara",
                    "concert",
                    "day",
                    "public",
                ),
                ("2023-05-12", "Flight home for summer", "travel", "day", "public"),
                ("2023-07-28", "In Pieces in Portland", "show", "day", "public"),
                (
                    "2023-08-01",
                    "First NY apartment (Flatbush)",
                    "move",
                    "day",
                    "public",
                ),
                ("2023-09-06", "Start of sophomore year", "school", "day", "public"),
                ("2024-08-21", "Sober date", "health", "day", "private"),
            ],
        )
        self.assertTrue(all("note" not in event for event in events))

    def test_optional_fields_and_same_day_range(self):
        event = self.event | {"end_date": "2022-09-05", "note": "Private context"}
        self.assertEqual(self.load([event]), [event])
        self.assertEqual(self.load([]), [])

    def test_unknown_fields_and_missing_required_fields(self):
        for field in ("id", "date", "precision", "title", "category", "visibility"):
            with self.subTest(field=field):
                event = self.event.copy()
                del event[field]
                with self.assertRaises(ValidationError):
                    self.load([event])
        with self.assertRaises(ValidationError):
            self.load([self.event | {"unexpected": "value"}])

    def test_invalid_values(self):
        for field, values in {
            "id": [
                "Uppercase",
                "bad_slug",
                "-leading",
                "trailing-",
                "beets-library-import",
            ],
            "date": [
                "2022-02-30",
                "2023-02-29",
                "2022-9-05",
                "2022-09-05T00:00:00Z",
                None,
            ],
            "end_date": ["2022-02-30", None],
            "precision": ["week", None],
            "category": ["unknown", None],
            "visibility": ["PRIVATE", "unknown", None],
            "title": ["", None],
            "note": [None, 123],
        }.items():
            for value in values:
                with (
                    self.subTest(field=field, value=value),
                    self.assertRaises(ValidationError),
                ):
                    self.load([self.event | {field: value}])

    def test_duplicate_ids_with_different_content(self):
        duplicate = self.event | {"title": "Another title", "visibility": "public"}
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.load([self.event, duplicate])

    def test_end_before_start(self):
        with self.assertRaisesRegex(ValueError, "precedes"):
            self.load([self.event | {"end_date": "2022-09-04"}])

    def test_all_declared_precisions_and_categories(self):
        schema = json.loads(SCHEMA.read_text())
        properties = schema["items"]["properties"]
        for field in ("precision", "category", "visibility"):
            for value in properties[field]["enum"]:
                with self.subTest(field=field, value=value):
                    self.load([self.event | {field: value}])

    def test_cli_rejects_missing_visibility_without_echoing_notes(self):
        event = copy.deepcopy(self.event)
        del event["visibility"]
        event["note"] = "Private note sentinel"
        self.data.write_text(json.dumps([event]))
        result = subprocess.run(
            [str(TOOL), "validate", str(self.data), str(SCHEMA)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("required", result.stderr)
        self.assertNotIn(event["note"], result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()

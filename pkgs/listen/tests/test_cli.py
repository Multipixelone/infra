"""Integration tests against a real throwaway beets database and media files."""

import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import yaml

FIELDS = json.loads(
    (Path(__file__).parents[1] / "listen_queue/album_fields.json").read_text()
)

CREATE = """
import json, os, sys
from contextlib import redirect_stdout
from pathlib import Path
from beets.library import Library, Item
root = Path(os.environ['LISTEN_STATE_DIR']).parent
with redirect_stdout(sys.stderr):
    lib = Library(str(root / 'library.db'), str(root / 'music'))
ids = []
for index, row in enumerate(json.loads(os.environ['LISTEN_FIXTURES'])):
    items = []
    for track, length in enumerate(row.get('lengths', [row.get('minutes', 30) * 60])):
        path = root / 'music' / f'{index}-{track}.flac'
        path.write_bytes(b'untouched media')
        item = Item(path=str(path), album=row['album'], albumartist=row.get('artist', 'Artist'),
                    artist=row.get('artist', 'Artist'), title=f'Track {track}',
                    length=length, year=row.get('year', 2020), genres=[row.get('genre', 'Jazz')],
                    label=row.get('label', 'Label'), track=track+1)
        for name, values in row.get('scores', {}).items():
            if values[track] is not None:
                item[name] = values[track]
        for name, value in row.get('identifiers', {}).items():
            item[name] = value
        items.append(item)
    album = lib.add_album(items)
    if row.get('state'):
        album['listen_state'] = row['state']
    album['added'] = row.get('added', 1767225600)
    album.store(inherit=False)
    ids.append(album.id)
print(json.dumps(ids))
"""


class LibraryCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="listen-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "music").mkdir()
        self.config = self.root / "config.yaml"
        self.config.write_text(
            yaml.safe_dump(
                {
                    "library": str(self.root / "library.db"),
                    "directory": str(self.root / "music"),
                    "plugins": ["types", "inline"],
                    "types": {"listened_at": "date"},
                    "album_fields": FIELDS,
                }
            )
        )
        self.env = {
            **os.environ,
            "BEETSDIR": str(self.root),
            "XDG_CONFIG_HOME": str(self.root),
            "LISTEN_BEETS_CONFIG": str(self.config),
            "LISTEN_BEETS_LOCK": str(self.root / ".import.lock"),
            "LISTEN_STATE_DIR": str(self.root / "state"),
            "LISTEN_COMMUTECOMPASS": str(self.root / "no-commutecompass"),
            "LISTEN_BEETS_LOCK_TIMEOUT": "2",
            "LISTEN_SQLITE_BUSY_TIMEOUT": "2",
        }

    def create(self, *rows):
        result = subprocess.run(
            [sys.executable, "-c", CREATE],
            env={**self.env, "LISTEN_FIXTURES": json.dumps(rows)},
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def invoke(self, *args, exit_code=0):
        result = subprocess.run(
            [sys.executable, "-m", "listen_queue.cli", *map(str, args), "--json"],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )
        self.assertEqual(result.returncode, exit_code, result.stderr + result.stdout)
        envelope = json.loads(result.stdout)
        self.assertEqual(envelope["schema"], 1)
        self.assertEqual(envelope["ok"], exit_code == 0)
        self.assertEqual(
            set(envelope),
            {"schema", "command", "ok", "data" if exit_code == 0 else "error"},
        )
        return envelope["data" if exit_code == 0 else "error"]

    def queue_all(self):
        for album in self.invoke("list", "--state", "all")["albums"]:
            self.invoke("add", "--id", album["id"])


class CommandTests(LibraryCase):
    def test_seed_missing_configuration_json(self):
        self.create({"album": "One"})
        self.env["LISTEN_PLEX_SOURCE"] = "listen list:)"
        self.env["LISTEN_PLEX_DONE_SOURCE"] = "albums im rocking w"
        for variable in ("LISTEN_PLEX_SOURCE", "LISTEN_PLEX_DONE_SOURCE"):
            value = self.env.pop(variable)
            error = self.invoke("seed-plex", exit_code=78)
            self.assertEqual(error["code"], "configuration_invalid")
            self.assertIn(variable, error["message"])
            self.assertFalse((self.root / "state").exists())
            self.env[variable] = value

    def test_add_diacritics_and_ambiguous(self):
        first, second = self.create(
            {"album": "Álbum", "artist": "Björk"},
            {"album": "Album Deluxe", "artist": "Björk"},
        )
        error = self.invoke("add", "BJORK ALBUM", exit_code=66)
        self.assertEqual(error["code"], "ambiguous")
        self.assertEqual(
            {a["id"] for a in error["details"]["candidates"]}, {first, second}
        )
        self.assertEqual(self.invoke("list")["albums"], [])
        data = self.invoke("add", "album", "--id", first)
        self.assertEqual(data["album"]["listen_state"], "queued")
        self.assertEqual(self.invoke("add", "deluxe")["album"]["id"], second)

    def test_no_query_passthrough(self):
        self.create({"album": "Normal"})
        for text in ("album:Normal", "id:1", ":.*", "listen_state:queued", "'"):
            self.assertEqual(
                self.invoke("add", text, exit_code=65)["code"], "not_found"
            )
        self.assertEqual(self.invoke("list")["albums"], [])

    def test_done_drop_requeue_and_dates(self):
        (album_id,) = self.create({"album": "One"})
        done = self.invoke("done", "--id", album_id)["album"]
        self.assertEqual(done["listen_state"], "listened")
        self.assertTrue(done["listened_at"].endswith("Z"))
        dropped = self.invoke("drop", "One")["album"]
        self.assertEqual(dropped["listen_state"], "dropped")
        self.assertEqual(dropped["listened_at"], done["listened_at"])
        queued = self.invoke("add", "--id", album_id)["album"]
        self.assertEqual(queued["listen_state"], "queued")
        self.assertEqual(queued["listened_at"], done["listened_at"])
        self.assertEqual(self.invoke("list", "--state", "listened")["albums"], [])

    def test_choice_is_explicit_and_consumed(self):
        (album_id,) = self.create({"album": "One", "state": "queued"})
        self.invoke("pick", "--count", 1, "--max-minutes", 45)
        self.invoke("pick", "--pool", "--max-minutes", 45)
        self.assertEqual(self.invoke("done", exit_code=66)["code"], "needs_album")
        self.invoke("pick", "--choose", album_id)
        self.assertEqual((self.root / "state").stat().st_mode & 0o777, 0o700)
        self.assertEqual(
            (self.root / "state/last-pick.json").stat().st_mode & 0o777, 0o600
        )
        self.assertEqual(self.invoke("done")["album"]["id"], album_id)
        self.assertFalse((self.root / "state/last-pick.json").exists())
        self.assertEqual(self.invoke("done", exit_code=66)["code"], "needs_album")
        self.invoke("add", "--id", album_id)
        self.invoke("pick", "--choose", album_id)
        self.assertEqual(self.invoke("drop")["album"]["listen_state"], "dropped")

    def test_explicit_mark_clears_any_choice(self):
        first, second = self.create(
            {"album": "One", "state": "queued"}, {"album": "Two", "state": "queued"}
        )
        self.invoke("pick", "--choose", first)
        self.invoke("done", "--id", second)
        self.assertEqual(self.invoke("done", exit_code=66)["code"], "needs_album")

    def test_invalid_choice_and_missing_id(self):
        (album_id,) = self.create({"album": "One"})
        self.assertEqual(
            self.invoke("pick", "--choose", album_id, exit_code=66)["code"],
            "not_queued",
        )
        self.invoke("add", "--id", album_id)
        self.invoke("pick", "--choose", album_id, "--count", 1, exit_code=64)
        self.invoke("done", "One", "--id", album_id, exit_code=64)
        self.assertEqual(
            self.invoke("add", "--id", 99999, exit_code=65)["code"], "not_found"
        )

    def test_library_only_mutations(self):
        (album_id,) = self.create({"album": "One"})
        before = {
            p.name: (p.read_bytes(), p.stat().st_mtime_ns)
            for p in (self.root / "music").iterdir()
        }
        self.invoke("add", "--id", album_id)
        self.invoke("done", "--id", album_id)
        result = subprocess.run(
            [
                sys.executable,
                "-c",
                "from beets.library import Library; import os; lib=Library(os.path.dirname(os.environ['LISTEN_STATE_DIR'])+'/library.db'); assert all(i.get('listen_state', with_album=False) is None and i.get('listened_at', with_album=False) is None for i in lib.items())",
            ],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            before,
            {
                p.name: (p.read_bytes(), p.stat().st_mtime_ns)
                for p in (self.root / "music").iterdir()
            },
        )

    def test_stale_and_corrupt_receipts(self):
        (album_id,) = self.create({"album": "One", "state": "listened"})
        state = self.root / "state"
        state.mkdir()
        (state / "last-pick.json").write_text(
            json.dumps(
                {
                    "schema": 1,
                    "library": str(self.root / "library.db"),
                    "album_id": album_id,
                }
            )
        )
        self.assertEqual(self.invoke("done", exit_code=66)["code"], "needs_album")
        (state / "last-pick.json").write_text("{bad")
        self.assertEqual(self.invoke("done", exit_code=78)["code"], "state_invalid")

    def test_lock_serializes_mutation(self):
        (album_id,) = self.create({"album": "One"})
        with open(self.root / ".import.lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            child = subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "listen_queue.cli",
                    "add",
                    "--id",
                    str(album_id),
                    "--json",
                ],
                env=self.env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            try:
                time.sleep(0.25)
                self.assertIsNone(child.poll())
                fcntl.flock(lock, fcntl.LOCK_UN)
                stdout, stderr = child.communicate(timeout=10)
                self.assertEqual(child.returncode, 0, stderr + stdout)
                self.assertEqual(
                    json.loads(stdout)["data"]["album"]["listen_state"], "queued"
                )
            finally:
                if child.poll() is None:
                    child.kill()
                    child.communicate()

    def test_json_before_subcommand_and_parse_errors(self):
        self.create({"album": "One"})
        self.invoke("--json", "list")
        for args in (
            ("pick", "--max-minutes", "nan"),
            ("pick", "--count", "0"),
            ("add",),
            ("add", " "),
        ):
            self.assertEqual(
                self.invoke(*args, exit_code=64)["code"], "invalid_arguments"
            )


class SelectionTests(LibraryCase):
    def test_cap_fill_pool_and_unknown_length(self):
        ids = self.create(
            *(
                {"album": str(minutes), "minutes": minutes, "state": "queued"}
                for minutes in (20, 35, 45, 55)
            ),
            {"album": "Unknown", "lengths": [0], "state": "queued"},
        )
        data = self.invoke("pick", "--max-minutes", 30, "--count", 3)
        self.assertEqual(
            data["cap"], {"minutes": 30.0, "source": "flag", "reason": None}
        )
        self.assertEqual([a["id"] for a in data["albums"]], ids[:3])
        self.assertEqual([a["over_minutes"] for a in data["albums"]], [0, 5, 15])
        pool = self.invoke("pick", "--pool", "--max-minutes", 30, "--artist", "Nobody")
        self.assertEqual(len(pool["albums"]), 5)
        self.assertIsNone(pool["requested_count"])
        self.assertTrue(all(not a["matches_filters"] for a in pool["albums"]))
        self.assertIsNone(pool["albums"][-1]["fits"])
        self.assertEqual(data["unknown_length_ids"], [ids[-1]])

    def test_commute_default_and_empty(self):
        self.create({"album": "Unmarked"})
        data = self.invoke("pick")
        self.assertEqual(
            data["cap"],
            {
                "minutes": 45,
                "source": "default",
                "reason": "commute_command_unavailable",
            },
        )
        self.assertEqual(data["albums"], [])

    def test_inline_means_missing_zero_and_classifiers(self):
        first, missing = self.create(
            {
                "album": "Scores",
                "lengths": [600, 600, 600],
                "state": "queued",
                "scores": {
                    "mood_happy": [0, 0.8, None],
                    "is_instrumental": [0, 0.6, None],
                    "bpm": [100, 140, 0],
                    "mood_mirex_cluster_1": [0.3, 0.3, None],
                    "mood_mirex_cluster_2": [0.3, 0.3, None],
                    "genre_rosamerica": ["POP", "pop", "jaz"],
                },
            },
            {"album": "Missing", "state": "queued"},
        )
        albums = {
            a["id"]: a
            for a in self.invoke("pick", "--pool", "--max-minutes", 45)["albums"]
        }
        scored = albums[first]
        self.assertEqual(
            scored["scores"]["happy"],
            {"score": 0.4, "present": True, "scored_tracks": 2},
        )
        self.assertEqual(scored["scores"]["instrumental"]["score"], 0.3)
        self.assertEqual(scored["bpm"], 120)
        self.assertEqual(scored["mood_mirex"]["cluster"], 1)
        self.assertEqual(
            scored["genre_rosamerica"],
            {"genre": "pop", "present": True, "scored_tracks": 3},
        )
        self.assertTrue(
            all(not score["present"] for score in albums[missing]["scores"].values())
        )
        self.assertIsNone(albums[missing]["mood_mirex"]["cluster"])
        names = {m["name"] for m in self.invoke("moods")["moods"]}
        self.assertIn("aggressive", names)
        self.assertNotIn("bpm", names)
        self.assertNotIn("mirex_1", names)

    def test_metadata_bounds_and_pool_reasons(self):
        matching, other = self.create(
            {
                "album": "Match",
                "artist": "Björk",
                "label": "Éditions",
                "year": 1995,
                "added": 1767225600,
                "state": "queued",
                "scores": {
                    "bpm": [120],
                    "mood_mirex_cluster_3": [0.8],
                    "genre_rosamerica": ["pop"],
                },
            },
            {
                "album": "Other",
                "artist": "Other",
                "label": "Other",
                "year": 2020,
                "state": "queued",
            },
        )
        options = (
            "--artist",
            "BJORK",
            "--genre",
            "jazz",
            "--label",
            "editions",
            "--decade",
            "1990s",
            "--year-from",
            1994,
            "--bpm-min",
            110,
            "--bpm-max",
            130,
            "--added-after",
            "2025-12-31",
            "--added-before",
            "2026-01-02T01:00:00+01:00",
            "--mirex-cluster",
            3,
            "--rosamerica",
            "POP",
            "--min-minutes",
            20,
            "--max-minutes",
            45,
        )
        data = self.invoke("pick", *options)
        self.assertEqual([a["id"] for a in data["albums"]], [matching])
        self.assertEqual(data["filters"]["year_to"], 1999)
        pool = self.invoke("pick", "--pool", *options)
        rejected = next(a for a in pool["albums"] if a["id"] == other)
        self.assertIn("label", rejected["filter_reasons"])
        self.assertIn("bpm-min", rejected["filter_reasons"])
        self.assertEqual(
            self.invoke(
                "pick",
                "--label",
                "editions",
                "--exclude-label",
                "editions",
                "--max-minutes",
                45,
            )["albums"],
            [],
        )
        self.assertEqual(
            self.invoke(
                "pick",
                "--added-after",
                "2026-01-01",
                "--added-before",
                "2026-01-02",
                "--max-minutes",
                45,
            )["albums"],
            [],
        )

    def test_all_moods_and_invalid_values(self):
        names = [
            "acoustic",
            "aggressive",
            "electronic",
            "happy",
            "sad",
            "party",
            "relaxed",
            "danceable",
            "instrumental",
        ]
        scores = {"mood_" + name: [0.0, 1.0, None, "bad", "nan", 2.0] for name in names}
        scores["danceable"] = scores.pop("mood_danceable")
        scores["is_instrumental"] = scores.pop("mood_instrumental")
        self.create(
            {"album": "All", "state": "queued", "lengths": [60] * 6, "scores": scores}
        )
        album = self.invoke("pick", "--pool", "--max-minutes", 45)["albums"][0]
        for name in names:
            self.assertEqual(
                album["scores"][name],
                {"score": 0.5, "present": True, "scored_tracks": 2},
            )

    def test_rosamerica_tie_and_metadata_boundaries(self):
        self.create(
            {
                "album": "Tie",
                "artist": "Artist",
                "genre": "Jazz",
                "state": "queued",
                "lengths": [600, 600],
                "scores": {"genre_rosamerica": ["pop", "jaz"], "bpm": [120, 120]},
            }
        )
        data = self.invoke(
            "pick", "--bpm-min", 120, "--bpm-max", 120, "--max-minutes", 45
        )
        self.assertEqual(len(data["albums"]), 1)

        self.assertEqual(data["albums"][0]["genre_rosamerica"]["genre"], "jaz")
        for options in (("--exclude-artist", "artist"), ("--exclude-genre", "jazz")):
            self.assertEqual(
                self.invoke("pick", *options, "--max-minutes", 45)["albums"], []
            )
        data = self.invoke(
            "pick", "--artist", "Missing", "--artist", "Artist", "--max-minutes", 45
        )
        self.assertEqual(len(data["albums"]), 1)

    def test_instrumental_boolean_inputs(self):
        self.create(
            {
                "album": "Booleans",
                "state": "queued",
                "lengths": [600, 600, 600],
                "scores": {"is_instrumental": [True, False, None]},
            }
        )
        score = self.invoke("pick", "--pool", "--max-minutes", 45)["albums"][0][
            "scores"
        ]["instrumental"]
        self.assertEqual(score, {"score": 0.5, "present": True, "scored_tracks": 2})

    def test_mood_thresholds_keep_unknown_unless_required(self):
        low, high, unknown = self.create(
            {"album": "Low", "state": "queued", "scores": {"mood_happy": [0]}},
            {"album": "High", "state": "queued", "scores": {"mood_happy": [0.8]}},
            {"album": "Unknown", "state": "queued"},
        )
        data = self.invoke(
            "pick",
            "--mood",
            "happy",
            "--avoid-mood",
            "sad",
            "--min-score",
            "happy=0.5",
            "--count",
            10,
            "--max-minutes",
            45,
        )
        self.assertEqual({a["id"] for a in data["albums"]}, {high, unknown})
        data = self.invoke(
            "pick", "--min-score", "happy=0.5", "--scored-only", "--max-minutes", 45
        )
        self.assertEqual([a["id"] for a in data["albums"]], [high])
        data = self.invoke(
            "pick", "--max-score", "happy=0", "--scored-only", "--max-minutes", 45
        )
        self.assertEqual([a["id"] for a in data["albums"]], [low])

    def test_invalid_filters(self):
        self.create({"album": "One"})
        for options in (
            ("--mood", "unconfigured"),
            ("--scored-only",),
            ("--min-score", "happy=nan"),
            ("--min-score", "happy=0.8", "--max-score", "happy=0.2"),
            ("--decade", "1995"),
            ("--decade", "1990", "--year-from", "2020"),
            ("--added-after", "invalid"),
            ("--added-before", "2026-01-01T12:00:00"),
            ("--bpm-min", 150, "--bpm-max", 100),
        ):
            self.invoke("pick", *options, exit_code=64)

    def test_additional_configured_mood(self):
        self.create({"album": "One", "state": "queued"})
        config = yaml.safe_load(self.config.read_text())
        config["album_fields"]["listen_calm"] = "0.9"
        config["album_fields"]["listen_calm_scored_tracks"] = "len(items)"
        self.config.write_text(yaml.safe_dump(config))
        self.assertIn("calm", {m["name"] for m in self.invoke("moods")["moods"]})
        albums = self.invoke(
            "pick", "--mood", "calm", "--scored-only", "--max-minutes", 45
        )["albums"]
        self.assertEqual(albums[0]["scores"]["calm"]["score"], 0.9)


if __name__ == "__main__":
    unittest.main()

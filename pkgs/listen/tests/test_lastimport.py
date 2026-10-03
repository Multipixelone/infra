"""The pinned beets lastimport command is exercised with mocked last.fm pages."""

import subprocess
import sys

import yaml
from test_cli import LibraryCase

REFRESH = """
import os
from unittest.mock import patch
from beets import ui
from beets.library import Item
from beets import plugins

def page(user, page, limit):
    assert user == 'fixture-user'
    return [{'mbid': '', 'artist': 'Artist', 'name': f'Track {page - 1}', 'playcount': page * 3}], 2

with patch('beetsplug.lastimport.fetch_tracks', side_effect=page) as fetch, \
     patch.object(Item, 'write', side_effect=AssertionError('must not write tags')), \
     patch.object(Item, 'try_write', side_effect=AssertionError('must not write tags')):
    ui._raw_main(['-c', os.environ['LISTEN_BEETS_CONFIG'], '-p', 'lastimport', 'lastimport'])
    assert fetch.call_count == 2
assert [plugin.name for plugin in plugins.find_plugins()] == ['lastimport']
"""


class LastImportTests(LibraryCase):
    def test_full_history_updates_db_without_tags_or_other_plugins(self):
        self.create({"album": "One", "lengths": [60, 60]})
        config = yaml.safe_load(self.config.read_text())
        config["lastfm"] = {"user": "fixture-user"}
        config["import"] = {"write": True}
        # A plugin that must never be loaded by the service's -p override.
        config["plugins"] = ["missing_fixture_plugin"]
        self.config.write_text(yaml.safe_dump(config))
        before = {
            p.name: (p.read_bytes(), p.stat().st_mtime_ns)
            for p in (self.root / "music").iterdir()
        }
        result = subprocess.run(
            [sys.executable, "-c", REFRESH],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        album = self.invoke("most-played")["albums"][0]
        self.assertEqual(album["play_count"], 9)
        self.assertEqual(album["plays_per_track"], 4.5)
        self.assertEqual(
            before,
            {
                p.name: (p.read_bytes(), p.stat().st_mtime_ns)
                for p in (self.root / "music").iterdir()
            },
        )

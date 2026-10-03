"""Plex is mocked; apply tests only write to a throwaway beets library."""

from types import SimpleNamespace
from unittest.mock import patch

from listen_queue.errors import ListenError
from listen_queue.library import Queue
from listen_queue.plex import discover, seed
from test_cli import LibraryCase

RELEASE = "11111111-1111-1111-1111-111111111111"
GROUP = "22222222-2222-2222-2222-222222222222"


def plex_album(key="10", artist="Artist", title="One", guids=(), tracks=()):
    return SimpleNamespace(
        type="album",
        ratingKey=key,
        parentTitle=artist,
        title=title,
        guid=f"plex://album/{key}",
        guids=[SimpleNamespace(id=g) for g in guids],
        tracks=lambda: list(tracks),
    )


def plex_track(album, key="20", guid="plex://track/20"):
    return SimpleNamespace(
        type="track",
        ratingKey=key,
        title="Track",
        guid=guid,
        guids=[],
        album=lambda: album,
    )


def container(kind, items, title="Albums I SHOULD listen to"):
    return SimpleNamespace(
        type=kind,
        ratingKey="100" if kind == "playlist" else "200",
        title=title,
        items=lambda: list(items),
    )


def plex_server(playlists=(), collections=()):
    return SimpleNamespace(
        playlists=lambda playlistType: list(playlists),
        library=SimpleNamespace(
            sections=lambda: [
                SimpleNamespace(type="artist", collections=lambda: list(collections))
            ]
        ),
    )


class PlexTests(LibraryCase):
    def queue(self):
        return Queue(self.config, self.root / "state")

    def test_collection_and_track_playlist_deduplicate(self):
        album = plex_album()
        track = plex_track(album)
        album.tracks = lambda: [track]
        server = plex_server(
            [container("playlist", [track, track])], [container("collection", [album])]
        )
        sources, albums, unsupported = discover(server)
        self.assertEqual({s["kind"] for s in sources}, {"collection", "playlist"})
        self.assertEqual(len(albums), 1)
        self.assertEqual(albums[0].track_ids, {"20"})
        self.assertEqual(unsupported, [])

    def test_dry_run_apply_and_repeat_receipt(self):
        (album_id,) = self.create({"album": "One", "state": "listened"})
        queue = self.queue()
        server = plex_server([container("playlist", [plex_album(title="Óne")])])
        result = seed(queue, plex=server)
        self.assertFalse(result["applied"])
        self.assertEqual(result["matched"][0]["method"], "albumartist_album")
        self.assertEqual(queue.lib.get_album(album_id).get("listen_state"), "listened")
        self.assertFalse((self.root / "state").exists())
        result = seed(queue, apply=True, plex=server)
        self.assertEqual(result["queued_ids"], [album_id])
        self.assertEqual(result["matched"][0]["album"]["listen_state"], "queued")
        self.assertEqual(
            (self.root / "state/plex-seed.json").stat().st_mode & 0o777, 0o600
        )
        self.invoke("done", "--id", album_id)
        with (
            self.assertRaises(ListenError) as error,
            patch("listen_queue.plex.connect") as connect,
        ):
            seed(queue, apply=True)
        self.assertEqual(error.exception.code, "already_seeded")
        connect.assert_not_called()
        self.assertEqual(queue.lib.get_album(album_id).get("listen_state"), "listened")
        self.assertTrue(seed(queue, plex=server)["already_seeded"])

    def test_musicbrainz_precedes_names(self):
        intended, _namesake = self.create(
            {"album": "Different", "identifiers": {"mb_albumid": RELEASE}},
            {"album": "One"},
        )
        queue = self.queue()
        server = plex_server(
            [container("playlist", [plex_album(guids=["mbid://" + RELEASE])])]
        )
        result = seed(queue, plex=server)
        self.assertEqual(result["matched"][0]["album"]["id"], intended)
        self.assertEqual(result["matched"][0]["method"], "mb_albumid")

    def test_releasegroup_and_track_associations(self):
        for field, value, guids, tracks, method in (
            (
                "mb_releasegroupid",
                GROUP,
                ["musicbrainz://release-group/" + GROUP],
                [],
                "mb_releasegroupid",
            ),
            ("plex_guid", "plex://track/20", [], ["guid"], "plex_guid"),
            ("plex_ratingkey", 20, [], ["key"], "plex_ratingkey"),
        ):
            with self.subTest(method=method):
                ids = self.create(
                    {"album": "Different " + method, "identifiers": {field: value}}
                )
                album = plex_album(key=method, guids=guids)
                track = plex_track(
                    album, guid="plex://track/20" if field == "plex_guid" else "other"
                )
                album.tracks = lambda track=track, tracks=tracks: (
                    [track] if tracks else []
                )
                result = seed(
                    self.queue(), plex=plex_server([container("playlist", [album])])
                )
                self.assertEqual(result["matched"][0]["album"]["id"], ids[0])
                self.assertEqual(result["matched"][0]["method"], method)

    def test_ambiguous_and_unmatched_never_guess(self):
        self.create({"album": "One"}, {"album": "One"})
        queue = self.queue()
        server = plex_server(
            [container("playlist", [plex_album(), plex_album("11", title="Missing")])]
        )
        result = seed(queue, apply=True, plex=server)
        self.assertEqual(result["matched"], [])
        self.assertEqual(result["queued_ids"], [])
        self.assertEqual(
            [r["reason"] for r in result["unmatched"]], ["ambiguous", "not_found"]
        )
        self.assertEqual(len(result["unmatched"][0]["candidates"]), 2)
        self.assertEqual(queue.albums(), [])

    def test_ambiguous_identifier_does_not_fall_back(self):
        self.create(
            {"album": "One", "identifiers": {"mb_albumid": RELEASE}},
            {"album": "Two", "identifiers": {"mb_albumid": RELEASE}},
        )
        result = seed(
            self.queue(),
            plex=plex_server(
                [container("playlist", [plex_album(guids=["mbid://" + RELEASE])])]
            ),
        )
        self.assertEqual(result["unmatched"][0]["reason"], "ambiguous")

    def test_source_missing_and_discovery_failure(self):
        self.create({"album": "One"})
        queue = self.queue()
        with self.assertRaises(ListenError) as error:
            seed(queue, plex=plex_server())
        self.assertEqual(error.exception.code, "not_found")
        with (
            patch(
                "listen_queue.plex.connect", side_effect=RuntimeError("secret-token")
            ),
            self.assertRaises(ListenError) as error,
        ):
            seed(queue)
        self.assertEqual(error.exception.exit_code, 75)
        self.assertNotIn("secret-token", error.exception.message)
        self.assertFalse((self.root / "state").exists())

    def test_unsupported_entry_is_reported(self):
        self.create({"album": "One"})
        entry = SimpleNamespace(type="movie", ratingKey="9", title="Video")
        result = seed(
            self.queue(), plex=plex_server([container("collection", [entry])])
        )
        self.assertEqual(result["unmatched"][0]["reason"], "unsupported_item")

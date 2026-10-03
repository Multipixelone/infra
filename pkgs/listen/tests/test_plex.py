"""Plex is mocked; apply tests only write to a throwaway beets library."""

import json
import os
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from listen_queue.cli import human, parser
from listen_queue.errors import ListenError
from listen_queue.library import Queue
from listen_queue.plex import discover, seed, sync
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


def container(kind, items, title="listen list:)"):
    return SimpleNamespace(
        type=kind,
        ratingKey="100" if kind == "playlist" else "200",
        title=title,
        items=lambda: list(items),
    )


def plex_server(playlists=(), collections=(), done_items=()):
    # Both configured sources exist by default; an empty source is valid.
    collections = [
        *collections,
        container("collection", done_items, "albums im rocking w"),
    ]
    return SimpleNamespace(
        playlists=lambda playlistType: list(playlists),
        library=SimpleNamespace(
            sections=lambda: [
                SimpleNamespace(type="artist", collections=lambda: list(collections))
            ]
        ),
    )


class PlexTests(LibraryCase):
    def setUp(self):
        super().setUp()
        sources = patch.dict(
            os.environ,
            {
                "LISTEN_PLEX_SOURCE": "listen list:)",
                "LISTEN_PLEX_DONE_SOURCE": "albums im rocking w",
            },
        )
        sources.start()
        self.addCleanup(sources.stop)

    def queue(self):
        return Queue(self.config, self.root / "state")

    def test_collection_and_track_playlist_deduplicate(self):
        album = plex_album()
        track = plex_track(album)
        album.tracks = lambda: [track]
        server = plex_server(
            [container("playlist", [track, track])], [container("collection", [album])]
        )
        sources, albums, unsupported = discover(server, "listen list:)")
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

    def test_configured_titles_exact_normalization_and_punctuation(self):
        self.create({"album": "One"})
        for title in ("listen list:)", "  LISTEN  list:)  "):
            with self.subTest(title=title):
                result = seed(
                    self.queue(),
                    plex=plex_server(
                        collections=[container("collection", [plex_album()], title)]
                    ),
                )
                self.assertEqual(result["groups"]["queued"]["counts"]["matched"], 1)
        for title in ("listen list", "listen list:) archive", "archive listen list:)"):
            with self.subTest(title=title), self.assertRaises(ListenError) as error:
                seed(
                    self.queue(),
                    plex=plex_server(
                        collections=[container("collection", [plex_album()], title)]
                    ),
                )
            self.assertEqual(error.exception.code, "not_found")
            self.assertEqual(error.exception.exit_code, 65)
        with patch.dict(os.environ, {"LISTEN_PLEX_SOURCE": "another queue"}):
            result = seed(
                self.queue(),
                plex=plex_server(
                    collections=[
                        container("collection", [plex_album()], "Another QUEUE")
                    ]
                ),
            )
        self.assertEqual(result["groups"]["queued"]["counts"]["matched"], 1)

    def test_configuration_invalid_before_connection(self):
        self.create({"album": "One"})
        for variable in ("LISTEN_PLEX_SOURCE", "LISTEN_PLEX_DONE_SOURCE"):
            for value in (None, "", "  "):
                with (
                    self.subTest(variable=variable, value=value),
                    patch.dict(os.environ),
                    patch("listen_queue.plex.connect") as connect,
                ):
                    if value is None:
                        os.environ.pop(variable, None)
                    else:
                        os.environ[variable] = value
                    with self.assertRaises(ListenError) as error:
                        seed(self.queue())
                    self.assertEqual(error.exception.code, "configuration_invalid")
                    self.assertEqual(error.exception.exit_code, 78)
                    connect.assert_not_called()
        with (
            patch.dict(os.environ, {"LISTEN_PLEX_DONE_SOURCE": "  LISTEN LIST:) "}),
            self.assertRaises(ListenError) as error,
        ):
            seed(self.queue())
        self.assertEqual(error.exception.code, "configuration_invalid")

    def test_missing_done_source_refuses_partial_apply(self):
        (album_id,) = self.create({"album": "One"})
        server = plex_server([container("playlist", [plex_album()])])
        server.library.sections = list
        with self.assertRaises(ListenError) as error:
            seed(self.queue(), apply=True, plex=server)
        self.assertEqual(error.exception.code, "not_found")
        self.assertIsNone(self.queue().lib.get_album(album_id).get("listen_state"))
        self.assertFalse((self.root / "state").exists())

    def test_groups_overlap_done_timestamp_and_pick_exclusion(self):
        queued, listened, overlap, unrelated = self.create(
            {"album": "Queue"},
            {"album": "Done", "state": "queued"},
            {"album": "Both", "state": "queued"},
            {"album": "Unrelated", "state": "dropped"},
        )
        queue = self.queue()
        queue.choose(overlap)
        server = plex_server(
            [
                container(
                    "playlist",
                    [plex_album("10", title="Queue"), plex_album("11", title="Both")],
                )
            ],
            done_items=[plex_album("12", title="Done"), plex_album("13", title="Both")],
        )
        before = (self.root / "state/last-pick.json").read_bytes()
        result = seed(queue, plex=server)
        self.assertEqual(result["overlap_ids"], [overlap])
        self.assertEqual(result["groups"]["queued"]["planned_ids"], [queued])
        self.assertEqual(
            result["groups"]["listened"]["planned_ids"], sorted([listened, overlap])
        )
        self.assertEqual(
            result["groups"]["queued"]["counts"],
            {"matched": 2, "unmatched": 0, "ambiguous": 0, "planned": 1},
        )
        self.assertEqual(
            result["groups"]["queued"]["matched"][1]["effective_state"], "listened"
        )
        self.assertEqual(result["queued_ids"], [])
        self.assertEqual(result["listened_ids"], [])
        self.assertIsNone(queue.lib.get_album(listened).get("listened_at"))
        self.assertEqual((self.root / "state/last-pick.json").read_bytes(), before)
        self.assertFalse((self.root / "state/plex-seed.json").exists())
        rendered = StringIO()
        with redirect_stdout(rendered):
            human("seed-plex", result)
        self.assertIn("queued: 2 matched", rendered.getvalue())
        self.assertIn("listened: 2 matched", rendered.getvalue())
        self.assertIn("listened wins", rendered.getvalue())
        result = seed(queue, apply=True, plex=server)
        self.assertEqual(result["queued_ids"], [queued])
        self.assertEqual(result["listened_ids"], sorted([listened, overlap]))
        for album_id in (listened, overlap):
            metadata = queue.metadata(queue.lib.get_album(album_id))
            self.assertEqual(metadata["listen_state"], "listened")
            self.assertTrue(metadata["listened_at"].endswith("Z"))
        self.assertEqual(
            queue.lib.get_album(listened).get("listened_at"),
            queue.lib.get_album(overlap).get("listened_at"),
        )
        self.assertFalse((self.root / "state/last-pick.json").exists())
        self.assertEqual(queue.lib.get_album(unrelated).get("listen_state"), "dropped")
        receipt = json.loads((self.root / "state/plex-seed.json").read_text())
        self.assertEqual(receipt["queued_ids"], [queued])
        self.assertEqual(receipt["listened_ids"], sorted([listened, overlap]))
        self.assertEqual(
            {s["target_state"] for s in receipt["sources"]}, {"queued", "listened"}
        )
        self.assertEqual(
            [a["id"] for a in self.invoke("pick", "--pool")["albums"]], [queued]
        )
        for item in queue.lib.items():
            self.assertIsNone(item.get("listen_state", with_album=False))
            self.assertIsNone(item.get("listened_at", with_album=False))
            self.assertEqual(
                Path(os.fsdecode(item.path)).read_bytes(), b"untouched media"
            )

    def test_unresolved_counts_in_each_group(self):
        self.create({"album": "One"}, {"album": "One"})
        result = seed(
            self.queue(),
            plex=plex_server(
                [
                    container(
                        "playlist", [plex_album(), plex_album("11", title="Missing")]
                    )
                ],
                done_items=[plex_album("12"), plex_album("13", title="Missing too")],
            ),
        )
        for state in ("queued", "listened"):
            group = result["groups"][state]
            self.assertEqual(
                group["counts"],
                {"matched": 0, "unmatched": 2, "ambiguous": 1, "planned": 0},
            )
            self.assertEqual(
                [r["reason"] for r in group["unmatched"]], ["ambiguous", "not_found"]
            )
            self.assertEqual(len(group["unmatched"][0]["candidates"]), 2)
            self.assertEqual({r["target_state"] for r in group["unmatched"]}, {state})
        self.assertFalse((self.root / "state").exists())

    def test_done_playlist_and_multiple_matching_containers(self):
        (album_id,) = self.create({"album": "One"})
        album = plex_album()
        track = plex_track(album)
        result = seed(
            self.queue(),
            plex=plex_server(
                [
                    container("playlist", [], "listen list:)"),
                    container("playlist", [track], " ALBUMS IM  ROCKING W "),
                ],
                done_items=[album],
            ),
        )
        group = result["groups"]["listened"]
        self.assertEqual(len(group["sources"]), 2)
        self.assertEqual(group["counts"]["matched"], 1)
        self.assertEqual(group["planned_ids"], [album_id])

    def test_apply_preserves_unrelated_last_pick(self):
        picked, _done = self.create(
            {"album": "Picked", "state": "queued"}, {"album": "Done"}
        )
        queue = self.queue()
        queue.choose(picked)
        before = (self.root / "state/last-pick.json").read_bytes()
        seed(
            queue,
            apply=True,
            plex=plex_server(
                [container("playlist", [])], done_items=[plex_album(title="Done")]
            ),
        )
        self.assertEqual((self.root / "state/last-pick.json").read_bytes(), before)

    def test_old_receipt_still_refuses_apply(self):
        self.create({"album": "One"})
        queue = self.queue()
        queue.state.write(
            "plex-seed.json",
            applied_at="2026-01-01T00:00:00Z",
            sources=[],
            queued_ids=[],
        )
        with (
            patch("listen_queue.plex.connect") as connect,
            self.assertRaises(ListenError) as error,
        ):
            seed(queue, apply=True)
        self.assertEqual(error.exception.code, "already_seeded")
        connect.assert_not_called()

    def test_help_documents_both_required_sources(self):
        help_text = parser().format_help()
        self.assertIn("LISTEN_PLEX_SOURCE", help_text)
        self.assertIn("LISTEN_PLEX_DONE_SOURCE", help_text)
        self.assertIn("There are no default source titles", help_text)


class SyncTests(LibraryCase):
    def setUp(self):
        super().setUp()
        sources = patch.dict(
            os.environ,
            {
                "LISTEN_PLEX_SOURCE": "listen list:)",
                "LISTEN_PLEX_DONE_SOURCE": "albums im rocking w",
            },
        )
        sources.start()
        self.addCleanup(sources.stop)

    def queue(self):
        return Queue(self.config, self.root / "state")

    def test_existing_states_timestamps_receipts_and_media_are_preserved(self):
        states = ("queued", "listened", "dropped", "future_state")
        ids = self.create(*({"album": state, "state": state} for state in states))
        queue = self.queue()
        for album in queue.lib.albums():
            album["listened_at"] = 1767225600
            album.store(inherit=False)
        queue.choose(ids[0])
        # Sync must not even read the one-time seed receipt.
        (self.root / "state/plex-seed.json").write_text("{invalid receipt}")
        before_db = (self.root / "library.db").read_bytes()
        before_state = {p.name: p.read_bytes() for p in (self.root / "state").iterdir()}
        before_media = {
            p.name: (p.read_bytes(), p.stat().st_mtime_ns)
            for p in (self.root / "music").iterdir()
        }
        server = plex_server(
            [
                container(
                    "playlist",
                    [plex_album(str(i), title=s) for i, s in enumerate(states)],
                )
            ],
            done_items=[plex_album(str(i + 10), title=s) for i, s in enumerate(states)],
        )
        for apply in (False, True, True):
            result = sync(queue, apply=apply, plex=server)
            self.assertEqual(result["queued_ids"], [])
            self.assertEqual(result["listened_ids"], [])
            self.assertEqual(result["overlap_ids"], [])
            for group in result["groups"].values():
                self.assertEqual(group["skipped_ids"], ids)
                self.assertEqual(group["planned_ids"], [])
                self.assertEqual(group["counts"]["skipped"], 4)
                for match in group["matched"]:
                    self.assertTrue(match["skipped"])
                    self.assertEqual(match["reason"], "existing_state")
                    self.assertEqual(
                        match["effective_state"], match["album"]["listen_state"]
                    )
            self.assertEqual((self.root / "library.db").read_bytes(), before_db)
        self.assertEqual(
            {p.name: p.read_bytes() for p in (self.root / "state").iterdir()},
            before_state,
        )
        self.assertEqual(
            {
                p.name: (p.read_bytes(), p.stat().st_mtime_ns)
                for p in (self.root / "music").iterdir()
            },
            before_media,
        )
        for album_id, state in zip(ids, states):
            album = queue.lib.get_album(album_id)
            self.assertEqual(album.get("listen_state"), state)
            self.assertEqual(album.get("listened_at"), 1767225600)

    def test_new_albums_precedence_dry_run_and_repeated_apply(self):
        queued, listened, both, empty, later = self.create(
            {"album": "Queue"},
            {"album": "Done"},
            {"album": "Both"},
            {"album": "Empty"},
            {"album": "Later"},
        )
        queue = self.queue()
        album = queue.lib.get_album(empty)
        album["listen_state"] = ""
        album.store(inherit=False)
        server = plex_server(
            [
                container(
                    "playlist",
                    [plex_album("1", title="Queue"), plex_album("2", title="Both")],
                )
            ],
            done_items=[
                plex_album("3", title="Done"),
                plex_album("4", title="Both"),
                plex_album("5", title="Empty"),
            ],
        )
        before = (self.root / "library.db").read_bytes()
        result = sync(queue, plex=server)
        self.assertFalse(result["applied"])
        self.assertEqual(result["groups"]["queued"]["planned_ids"], [queued])
        self.assertEqual(
            result["groups"]["listened"]["planned_ids"], [listened, both, empty]
        )
        self.assertEqual(result["overlap_ids"], [both])
        self.assertEqual(
            result["groups"]["queued"]["matched"][1]["effective_state"], "listened"
        )
        self.assertEqual(result["queued_ids"], [])
        self.assertEqual(result["listened_ids"], [])
        self.assertEqual((self.root / "library.db").read_bytes(), before)
        self.assertFalse((self.root / "state").exists())
        rendered = StringIO()
        with redirect_stdout(rendered):
            human("sync-plex", result)
        self.assertIn("use --apply to import new matches", rendered.getvalue())
        self.assertIn("listened wins", rendered.getvalue())
        result = sync(queue, apply=True, plex=server)
        self.assertEqual(result["queued_ids"], [queued])
        self.assertEqual(result["listened_ids"], [listened, both, empty])
        self.assertEqual(queue.lib.get_album(queued).get("listen_state"), "queued")
        self.assertIsNone(queue.lib.get_album(queued).get("listened_at"))
        timestamps = {
            queue.lib.get_album(i).get("listened_at") for i in (listened, both, empty)
        }
        self.assertEqual(len(timestamps), 1)
        self.assertTrue(all(timestamps))
        self.assertFalse((self.root / "state").exists())
        before = (self.root / "library.db").read_bytes()
        repeated = sync(queue, apply=True, plex=server)
        self.assertEqual(repeated["queued_ids"], [])
        self.assertEqual(repeated["listened_ids"], [])
        self.assertEqual((self.root / "library.db").read_bytes(), before)
        result = sync(
            queue,
            apply=True,
            plex=plex_server(
                [container("playlist", [plex_album(title="Later")])],
                done_items=[plex_album(title="Queue")],
            ),
        )
        self.assertEqual(result["queued_ids"], [later])
        self.assertEqual(result["listened_ids"], [])
        self.assertEqual(queue.lib.get_album(queued).get("listen_state"), "queued")
        for track in queue.lib.items():
            self.assertIsNone(track.get("listen_state", with_album=False))
            self.assertIsNone(track.get("listened_at", with_album=False))
            self.assertEqual(
                Path(os.fsdecode(track.path)).read_bytes(), b"untouched media"
            )

    def test_identifier_precedence_ambiguity_and_missing_source(self):
        intended, _duplicate, _other = self.create(
            {"album": "Different", "identifiers": {"mb_albumid": RELEASE}},
            {"album": "One"},
            {"album": "One"},
        )
        queue = self.queue()
        server = plex_server(
            [
                container(
                    "playlist",
                    [
                        plex_album("1", guids=["mbid://" + RELEASE]),
                        plex_album("2"),
                        plex_album("3", title="Missing"),
                    ],
                )
            ]
        )
        result = sync(queue, apply=True, plex=server)
        self.assertEqual(result["queued_ids"], [intended])
        self.assertEqual(result["matched"][0]["method"], "mb_albumid")
        self.assertEqual(
            [entry["reason"] for entry in result["unmatched"]],
            ["ambiguous", "not_found"],
        )
        self.assertEqual(len(result["unmatched"][0]["candidates"]), 2)
        before = (self.root / "library.db").read_bytes()
        server.library.sections = list
        with self.assertRaises(ListenError) as error:
            sync(queue, apply=True, plex=server)
        self.assertEqual(error.exception.code, "not_found")
        self.assertEqual((self.root / "library.db").read_bytes(), before)

    def test_cli_schema_and_sanitized_backend_failure(self):
        self.create({"album": "One"})
        from listen_queue.cli import main

        server = plex_server([container("playlist", [plex_album()])])
        environment = {
            **self.env,
            "LISTEN_PLEX_SOURCE": "listen list:)",
            "LISTEN_PLEX_DONE_SOURCE": "albums im rocking w",
        }
        for args in (("sync-plex", "--json"), ("--json", "sync-plex", "--apply")):
            output = StringIO()
            with (
                patch.dict(os.environ, environment),
                patch("listen_queue.plex.connect", return_value=server),
                redirect_stdout(output),
            ):
                self.assertEqual(main(list(args)), 0)
            envelope = json.loads(output.getvalue())
            self.assertEqual(set(envelope), {"schema", "command", "ok", "data"})
            self.assertEqual(envelope["schema"], 1)
            self.assertEqual(envelope["command"], "sync-plex")
            self.assertTrue(envelope["ok"])
        output = StringIO()
        with (
            patch.dict(os.environ, environment),
            patch(
                "listen_queue.plex.connect", side_effect=RuntimeError("secret-token")
            ),
            redirect_stdout(output),
        ):
            self.assertEqual(main(["sync-plex", "--json"]), 75)
        self.assertNotIn("secret-token", output.getvalue())
        self.assertEqual(
            json.loads(output.getvalue())["error"]["code"], "backend_unavailable"
        )

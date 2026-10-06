"""Discovery uses only a tiny export, throwaway beets, and a local test server."""

import base64
import json
import math
import os
import random
import threading
import unittest
import urllib.error
from contextlib import redirect_stdout
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO, StringIO
from pathlib import Path
from unittest.mock import patch

from listen_queue.cli import EXIT_HELP, main, parser
from listen_queue.discovery import discover, history_score, percentiles, ranked_sample
from listen_queue.errors import ListenError
from listen_queue.graph import Graph, TextClient, decode_column, decode_vector
from listen_queue.library import Queue
from test_cli import LibraryCase
from test_locking import held_lock

FIXTURE = Path(__file__).parent / "fixtures/albums.json"


class DecodingTests(unittest.TestCase):
    def test_vectors_signed_direction_and_validation(self):
        value = base64.b64encode(bytes([127, 129, 0, 0])).decode()
        vector = decode_vector(value, 4)
        self.assertAlmostEqual(vector[0], 1 / math.sqrt(2))
        self.assertAlmostEqual(vector[1], -1 / math.sqrt(2))
        self.assertAlmostEqual(sum(x * x for x in vector), 1)
        for encoded, size in ((value, 3), ("AAAAAA==", 4), ("not-base64!", 4)):
            with self.subTest(encoded=encoded), self.assertRaises(ValueError):
                decode_vector(encoded, size)

    def test_column_zero_is_missing_not_zero_score(self):
        column = {
            "scores": base64.b64encode(bytes([0, 1, 128, 255])).decode(),
            "min": 0,
            "max": 1,
        }
        self.assertEqual(decode_column(column, 4), [None, 0, 0.5, 1])
        column.update(min=-4, max=4)
        self.assertEqual(decode_column(column, 4), [None, -4, 0, 4])
        with self.assertRaises(ValueError):
            decode_column(column, 3)

    def test_graph_expands_pairs_and_positional_fields(self):
        data = json.loads(FIXTURE.read_text())
        data["albums"][0]["sound"]["style"]["labels"] = [[0, 0.08]]
        graph = Graph(data)
        self.assertEqual(
            graph.albums[1]["sound"]["style"]["labels"][0]["id"], "style:Jazz"
        )
        self.assertEqual(graph.albums[1]["essentia"]["danceable"]["value"], 0.8)
        self.assertIsNone(graph.albums[4]["essentia"]["voice_instrumental"]["value"])
        self.assertIn("clap:lo-fi", graph.details(1)["descriptors"])
        self.assertEqual(graph.descriptor("LO-FI"), "clap:lo-fi")
        with self.assertRaises(ListenError) as error:
            graph.descriptor("piano")
        self.assertEqual(error.exception.exit_code, 66)
        self.assertEqual(len(error.exception.details["descriptor_candidates"]), 2)

    def test_percentiles_ties_constants_and_missing(self):
        self.assertEqual(percentiles({1: 0, 2: 1, 3: None}), {1: 0, 2: 1, 3: 0.5})
        self.assertEqual(percentiles({1: 9, 2: 9, 3: 9}), {1: 0.5, 2: 0.5, 3: 0.5})
        self.assertEqual(percentiles({1: 0, 2: 0, 3: 1}), {1: 0.25, 2: 0.25, 3: 1})
        self.assertEqual(percentiles({1: 9}), {1: 0.5})

    def test_history_proxy_and_unknown_recency(self):
        now = datetime(2026, 10, 6, tzinfo=timezone.utc)
        old = {"plays_per_track": 20, "listened_at": "2026-01-01T00:00:00Z"}
        recent = {**old, "listened_at": "2026-10-05T00:00:00Z"}
        unknown = {**old, "listened_at": None}
        self.assertLess(history_score(old, "fresh", now)[0], 0.05)
        self.assertGreater(
            history_score(old, "rediscover", now)[0],
            history_score(recent, "rediscover", now)[0],
        )
        self.assertTrue(history_score(old, "rediscover", now)[1])
        self.assertEqual(history_score(unknown, "rediscover", now), (0, False))
        self.assertEqual(
            history_score({**old, "plays_per_track": 0}, "fresh", now), (1, True)
        )

    def test_seeded_random_pick_uses_top_five_and_no_duplicates(self):
        albums = [{"id": i, "score": 1 - i / 10} for i in range(10)]
        first = ranked_sample(albums, 1, random.Random(17))
        self.assertEqual(first, ranked_sample(albums, 1, random.Random(17)))
        self.assertLess(first[0]["id"], 5)
        selections = {
            ranked_sample(albums, 1, random.Random(seed))[0]["id"]
            for seed in range(100)
        }
        self.assertEqual(selections, set(range(5)))
        three = ranked_sample(albums, 3, random.Random(7))
        self.assertEqual(len({album["id"] for album in three}), 3)
        self.assertEqual(len(ranked_sample(albums, 20, random.Random(2))), 10)


class TextClientTests(unittest.TestCase):
    def client(self):
        with patch.dict(
            os.environ,
            {
                "LISTEN_TEXT_ENDPOINT": "http://127.0.0.1:1/api/embed-text",
                "LISTEN_TEXT_TIMEOUT": "2",
            },
        ):
            return TextClient("text:fixture")

    def test_request_and_normalized_response(self):
        payload = {"model_id": "text:fixture", "vector": [2] + [0] * 511}
        with patch(
            "listen_queue.graph.urllib.request.urlopen",
            return_value=BytesIO(json.dumps(payload).encode()),
        ) as request:
            self.assertEqual(self.client().embed(" rainy piano "), [1] + [0] * 511)
        self.assertEqual(
            json.loads(request.call_args.args[0].data), {"q": "rainy piano"}
        )
        self.assertEqual(
            request.call_args.args[0].get_header("Content-type"), "application/json"
        )
        self.assertLessEqual(request.call_args.kwargs["timeout"], 2)

    def test_endpoint_failures_have_dedicated_exit(self):
        for failure in (
            urllib.error.URLError("refused"),
            TimeoutError(),
            urllib.error.HTTPError("http://test", 503, "unavailable", {}, None),
        ):
            with (
                self.subTest(failure=failure),
                patch("listen_queue.graph.urllib.request.urlopen", side_effect=failure),
            ):
                with self.assertRaises(ListenError) as error:
                    self.client().embed("rainy piano")
                self.assertEqual(
                    (error.exception.code, error.exception.exit_code),
                    ("text_embedding_unavailable", 69),
                )

    def test_model_mismatch_and_invalid_payloads(self):
        for payload, code in (
            (
                {"model_id": "text:other", "vector": [1] + [0] * 511},
                "text_model_mismatch",
            ),
            (
                {"model_id": "text:fixture", "vector": [0] * 512},
                "text_embedding_invalid",
            ),
            (
                {"model_id": "text:fixture", "vector": [True] * 512},
                "text_embedding_invalid",
            ),
            (
                {"model_id": "text:fixture", "vector": [float("nan")] * 512},
                "text_embedding_invalid",
            ),
            ({"vector": [1]}, "text_embedding_invalid"),
        ):
            with (
                self.subTest(code=code),
                patch(
                    "listen_queue.graph.urllib.request.urlopen",
                    return_value=BytesIO(json.dumps(payload).encode()),
                ),
            ):
                with self.assertRaises(ListenError) as error:
                    self.client().embed("rainy piano")
                self.assertEqual(
                    (error.exception.code, error.exception.exit_code), (code, 69)
                )

    def test_rate_limit_retries_once_and_paces_phrases(self):
        payload = json.dumps(
            {"model_id": "text:fixture", "vector": [1] + [0] * 511}
        ).encode()
        limited = urllib.error.HTTPError(
            "http://test", 429, "busy", {"Retry-After": "1"}, None
        )
        with (
            patch(
                "listen_queue.graph.urllib.request.urlopen",
                side_effect=[limited, BytesIO(payload), BytesIO(payload)],
            ) as request,
            patch("listen_queue.graph.time.sleep") as sleep,
        ):
            client = self.client()
            client.embed("one")
            client.embed("two")
            self.assertEqual(request.call_count, 3)
            self.assertIn(1, [call.args[0] for call in sleep.call_args_list])
            self.assertTrue(
                any(0 < call.args[0] <= 0.55 for call in sleep.call_args_list)
            )
        with (
            patch(
                "listen_queue.graph.urllib.request.urlopen", side_effect=limited
            ) as request,
            patch("listen_queue.graph.time.sleep"),
        ):
            with self.assertRaises(ListenError):
                self.client().embed("one")
            self.assertEqual(request.call_count, 2)

    def test_invalid_phrases_do_not_call_endpoint(self):
        with patch("listen_queue.graph.urllib.request.urlopen") as request:
            for phrase in (" ", "x" * 241):
                with self.assertRaises(ListenError) as error:
                    self.client().embed(phrase)
                self.assertEqual(error.exception.exit_code, 64)
            request.assert_not_called()


class DiscoveryTests(LibraryCase):
    def setUp(self):
        super().setUp()
        self.create(
            {
                "album": "Alpha",
                "state": "queued",
                "scores": {"lastfm_play_count": [0], "mood_happy": [0.9]},
            },
            {
                "album": "Bravo",
                "listened_at": 1767225600,
                "scores": {"lastfm_play_count": [20], "mood_happy": [0.6]},
            },
            {
                "album": "Charlie",
                "state": "listened",
                "listened_at": 1791158400,
                "scores": {"lastfm_play_count": [30], "mood_happy": [0.2]},
            },
            {
                "album": "Delta",
                "state": "dropped",
                "scores": {"lastfm_play_count": [50]},
            },
            {"album": "Echo", "state": "queued", "minutes": 90},
        )
        self.export = self.root / "albums.json"
        self.export.write_bytes(FIXTURE.read_bytes())

    def update_export(self, change):
        data = json.loads(self.export.read_text())
        change(data)
        self.export.write_text(json.dumps(data))

    def test_find_order_count_and_whole_library(self):
        data = self.invoke("--json", "find", "--descriptor", "style:Jazz")
        self.assertEqual([album["id"] for album in data["albums"]], [1, 2, 3])
        self.assertIsNone(data["cap"])
        self.assertEqual(
            [
                album["id"]
                for album in self.invoke(
                    "find", "--descriptor", "style:Jazz", "--count", 10
                )["albums"]
            ],
            [1, 2, 3, 4],
        )
        self.assertEqual(
            self.invoke("pick", "--descriptor", "style:Jazz", "--max-minutes", 45)[
                "albums"
            ][0]["id"],
            1,
        )
        self.assertEqual(
            {
                album["id"]
                for album in self.invoke(
                    "pick", "--library", "--count", 10, "--max-minutes", 45
                )["albums"]
            },
            {1, 2, 3, 4},
        )

    def test_graph_find_reads_tracks_only_for_results_and_hydrates_them(self):
        from beets.library import Album

        original = Album.items
        read_ids = []

        def track_reads(album):
            read_ids.append(album.id)
            return original(album)

        with patch.dict(os.environ, self.env):
            queue = Queue(self.config, self.root / "state", read_only=True)
            try:
                with patch.object(Album, "items", track_reads):
                    data = discover(
                        queue,
                        parser().parse_args(
                            [
                                "find",
                                "--descriptor",
                                "style:Jazz",
                                "--count",
                                "1",
                            ]
                        ),
                    )
            finally:
                queue.close()
        self.assertTrue(read_ids)
        self.assertEqual(set(read_ids), {1})
        album = data["albums"][0]
        self.assertEqual(album["track_count"], 1)
        self.assertEqual(album["length_seconds"], 1800)
        self.assertEqual(album["scores"]["happy"]["score"], 0.9)

    def test_percentiles_do_not_change_with_queue_or_length_scope(self):
        with patch.dict(os.environ, self.env):
            queue = Queue(self.config, self.root / "state", read_only=True)
            try:
                pick = discover(
                    queue,
                    parser().parse_args(
                        [
                            "pick",
                            "--mood",
                            "happy",
                            "--max-minutes",
                            "45",
                        ]
                    ),
                    rng=random.Random(1),
                )
                find = discover(
                    queue,
                    parser().parse_args(
                        [
                            "find",
                            "--mood",
                            "happy",
                            "--count",
                            "1",
                        ]
                    ),
                )
            finally:
                queue.close()
        self.assertEqual(pick["albums"][0]["id"], 1)
        self.assertEqual(pick["albums"][0]["score"], find["albums"][0]["score"])

    def test_positive_metadata_soft_require_hard_and_dedup(self):
        soft = self.invoke("find", "--artist", "Nobody", "--count", 10)
        self.assertEqual(len(soft["albums"]), 5)
        self.assertEqual(
            self.invoke("find", "--require", "artist=Nobody")["albums"], []
        )
        data = self.invoke("find", "--genre", "Jazz", "--genre", "Other", "--count", 1)
        self.assertEqual(len(data["albums"][0]["score_breakdown"]), 1)
        data = self.invoke(
            "find", "--descriptor", "lo-fi", "--require", "descriptor=clap:lo-fi"
        )
        self.assertEqual([album["id"] for album in data["albums"]], [1, 2])
        self.assertEqual(len(data["albums"][0]["score_breakdown"]), 1)
        self.assertTrue(data["albums"][0]["score_breakdown"][0]["hard"])

    def test_scoring_equal_components_and_complete_graph_metadata(self):
        data = self.invoke(
            "find",
            "--descriptor",
            "clap:lo-fi",
            "--descriptor",
            "instruments:piano",
            "--mood",
            "happy",
            "--fresh",
        )
        for album in data["albums"]:
            entries = album["score_breakdown"]
            self.assertEqual(len(entries), 4)
            self.assertAlmostEqual(
                album["score"], sum(entry["normalized"] for entry in entries) / 4
            )
            self.assertLessEqual(len(album["why"]), 3)
            self.assertTrue(all(0 <= entry["normalized"] <= 1 for entry in entries))
            self.assertEqual(
                album["album_graph"]["vector"],
                json.loads(self.export.read_text())["albums"][album["id"] - 1][
                    "vector"
                ],
            )
        self.assertEqual(data["album_graph"]["text_vector_dimension"], 512)

    def test_full_columns_missing_values_and_no_coverage_penalty(self):
        # Piano is absent from displayed sound labels, but present in catalog columns.
        data = self.invoke("find", "--descriptor", "instruments:piano", "--count", 10)
        self.assertEqual([album["id"] for album in data["albums"]], [1, 3, 2])
        self.assertEqual(data["albums"][0]["score"], 1)
        self.assertEqual(
            data["albums"][0]["album_graph"]["sound"]["style"]["labels"], []
        )
        self.assertNotIn("coverage_note", data)
        data = self.invoke(
            "pick",
            "--library",
            "--pool",
            "--descriptor",
            "instruments:piano",
            "--max-minutes",
            45,
        )
        self.assertEqual({album["id"] for album in data["albums"]}, {1, 2, 3})

    def test_danceability_and_observed_vocal_category(self):
        soft = self.invoke("find", "--danceability", "0.5:0.9", "--count", 10)
        self.assertEqual({album["id"] for album in soft["albums"]}, {1, 2, 3})
        hard = self.invoke(
            "find",
            "--require",
            "danceability=0.5:0.9",
            "--require",
            "vocal=instrumental",
        )
        self.assertEqual([album["id"] for album in hard["albums"]], [1])
        self.assertEqual(
            {
                album["id"]
                for album in self.invoke(
                    "find", "--vocal", "instrumental", "--count", 10
                )["albums"]
            },
            {1, 2, 3},
        )

    def test_more_like_style_reference_exclusion_and_ambiguity(self):
        data = self.invoke("find", "--more-like", "Alpha", "--count", 10)
        self.assertEqual([album["id"] for album in data["albums"]], [2, 3, 4])
        self.assertEqual(data["albums"][0]["score_breakdown"][0]["space"], "style")
        hard = self.invoke("find", "--require", "more-like-id=1")
        self.assertEqual([album["id"] for album in hard["albums"]], [2])
        error = self.invoke("find", "--more-like", "Artist", exit_code=66)
        self.assertEqual(len(error["details"]["candidates"]), 5)
        self.invoke("find", "--more-like-id", 999, exit_code=65)
        self.invoke("find", "--more-like-id", 5, exit_code=65)

    def test_more_like_text_fallback(self):
        self.update_export(lambda data: data.update(model_id="text:fixture"))
        data = self.invoke("find", "--more-like-id", 1)
        self.assertEqual([album["id"] for album in data["albums"]], [3, 2, 4])
        self.assertEqual(data["albums"][0]["score_breakdown"][0]["space"], "text")

    def test_history_neutral_fresh_and_rediscover(self):
        neutral = self.invoke("find", "--count", 10)
        self.assertTrue(all(album["score"] == 0.5 for album in neutral["albums"]))
        self.assertEqual(
            [album["id"] for album in self.invoke("find", "--fresh")["albums"]],
            [1, 5, 2],
        )
        with patch.dict(os.environ, self.env):
            queue = Queue(self.config, self.root / "state", read_only=True)
            try:
                args = parser().parse_args(["find", "--rediscover", "--count", "10"])
                data = discover(
                    queue, args, now=datetime(2026, 10, 6, tzinfo=timezone.utc)
                )
            finally:
                queue.close()
        self.assertEqual(data["albums"][0]["id"], 2)
        self.assertEqual(data["history"]["recency_source"], "listened_at")
        self.assertEqual(
            [
                album["id"]
                for album in self.invoke("find", "--require", "rediscover")["albums"]
            ],
            [2],
        )

    def test_xtractor_unknown_neutral_and_hard_fails(self):
        data = self.invoke("find", "--mood", "happy", "--count", 10)
        missing = next(album for album in data["albums"] if album["id"] == 4)
        self.assertEqual(missing["score"], 0.5)
        self.assertEqual(
            {
                album["id"]
                for album in self.invoke("find", "--require", "mood=happy")["albums"]
            },
            {1, 2},
        )
        self.assertEqual(
            [
                album["id"]
                for album in self.invoke("find", "--require", "avoid-mood=happy")[
                    "albums"
                ]
            ],
            [3],
        )
        self.assertEqual(
            self.invoke("find", "--descriptor", "xtractor:happy")["albums"][0]["id"], 1
        )

    def test_descriptors_catalog_and_invalid_inputs(self):
        descriptors = self.invoke("descriptors")["descriptors"]
        self.assertIn("clap:lo-fi", {entry["id"] for entry in descriptors})
        self.assertIn("xtractor:happy", {entry["id"] for entry in descriptors})
        self.assertEqual(
            self.invoke("find", "--descriptor", "piano", exit_code=66)["code"],
            "ambiguous",
        )
        for options in (
            ("--descriptor", "unknown"),
            ("--vibe", " "),
            ("--vibe", "x" * 241),
            ("--danceability", "0.9:0.1"),
            ("--require", "unknown=foo"),
            ("--require", "more-like-id=nan"),
            ("--require", "mood=unknown"),
            ("--require", "fresh", "--rediscover"),
            ("--require", "vocal=any"),
        ):
            with self.subTest(options=options):
                self.invoke("find", *options, exit_code=64)

    def test_missing_stale_and_malformed_export(self):
        self.export.unlink()
        for args in (
            ("find", "--descriptor", "clap:lo-fi"),
            ("find", "--vibe", "piano"),
            ("descriptors",),
        ):
            self.assertEqual(
                self.invoke(*args, exit_code=72)["code"], "graph_unavailable"
            )
        self.assertEqual(len(self.invoke("find")["albums"]), 3)
        self.assertEqual(self.invoke("pick", "--max-minutes", 45)["albums"][0]["id"], 1)
        self.export.write_bytes(FIXTURE.read_bytes())
        self.update_export(lambda data: data.update(exported_at="2020-01-01T00:00:00Z"))
        self.assertTrue(
            self.invoke("find", "--descriptor", "clap:lo-fi")["album_graph"]["stale"]
        )
        self.update_export(lambda data: data.update(vector_encoding="unknown"))
        self.assertEqual(
            self.invoke("find", "--descriptor", "clap:lo-fi", exit_code=78)["code"],
            "graph_invalid",
        )
        self.assertEqual(len(self.invoke("find")["albums"]), 3)
        self.export.write_text("invalid JSON")
        self.assertEqual(
            self.invoke("descriptors", exit_code=78)["code"], "graph_invalid"
        )
        self.assertIn("72 graph_unavailable", EXIT_HELP)

    def test_reads_create_no_locks_or_receipts_and_find_can_be_queued(self):
        before = (self.root / "library.db").read_bytes()
        state = self.root / "state"
        state.mkdir()
        with held_lock(self.root / ".import.lock"), held_lock(state / ".lock"):
            self.invoke("find", "--descriptor", "clap:lo-fi")
            self.invoke("descriptors")
        self.assertEqual((self.root / "library.db").read_bytes(), before)
        self.assertEqual({path.name for path in state.iterdir()}, {".lock"})
        with (
            patch.dict(os.environ, self.env),
            patch("listen_queue.cli.shared_lock", side_effect=AssertionError),
            patch("listen_queue.cli.state_lock", side_effect=AssertionError),
            redirect_stdout(StringIO()),
        ):
            self.assertEqual(main(["--json", "find"]), 0)
        self.assertEqual(
            self.invoke("add", "--id", 2)["album"]["listen_state"], "queued"
        )
        self.invoke("pick", "--choose", 2)
        self.assertEqual(self.invoke("done")["album"]["id"], 2)

    def test_vibe_cli_with_local_endpoint_and_model_failure(self):
        payload = {"model_id": "text:fixture", "vector": [1] + [0] * 511}
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                requests.append(
                    json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                )
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(payload).encode())

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            self.env["LISTEN_TEXT_ENDPOINT"] = (
                f"http://127.0.0.1:{server.server_port}/api/embed-text"
            )
            data = self.invoke("find", "--vibe", "rainy piano")
            self.assertEqual([album["id"] for album in data["albums"]], [1, 3, 2])
            self.assertEqual(requests, [{"q": "rainy piano"}])
            hard = self.invoke("find", "--require", "vibe=rainy piano")
            self.assertEqual([album["id"] for album in hard["albums"]], [1, 3])
            payload["model_id"] = "text:wrong"
            self.assertEqual(
                self.invoke("find", "--vibe", "piano", exit_code=69)["code"],
                "text_model_mismatch",
            )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        self.assertEqual(
            self.invoke("find", "--vibe", "piano", exit_code=69)["code"],
            "text_embedding_unavailable",
        )
        self.assertEqual(
            len(self.invoke("find", "--descriptor", "style:Jazz")["albums"]), 3
        )

import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from openclaw_music import qobuz_matcher as matcher

SOURCE = {
    "spotify_id": "spotify-1",
    "artist": "Beyoncé",
    "album": "Renaissance (Deluxe Edition)",
    "spotify_url": "https://open.spotify.com/album/spotify-1",
}


class QobuzMatcherTests(unittest.TestCase):
    def request(self, **overrides):
        value = {
            "schema": 1,
            "source": SOURCE,
            "status": "selection_no_results",
            "query_stages": [],
            "candidates": [],
            "budget_truncated": False,
            "global_budget_incomplete": False,
        }
        value.update(overrides)
        return value

    def test_query_order_edition_stripping_and_deduplication(self):
        self.assertEqual(
            matcher.plan_queries("Renaissance (Deluxe Edition)", "Beyoncé"),
            [
                {
                    "stage": "title_artist",
                    "query": "Renaissance (Deluxe Edition) Beyoncé",
                },
                {
                    "stage": "edition_stripped_title_artist",
                    "query": "Renaissance Beyoncé",
                },
                {"stage": "title_only", "query": "Renaissance (Deluxe Edition)"},
            ],
        )
        self.assertEqual(len(matcher.plan_queries("25", "Adele")), 2)
        self.assertNotIn(" by ", matcher.plan_queries("25", "Adele")[0]["query"])

    def test_current_edition_qualifiers_are_retrieval_only(self):
        fixtures = (
            (
                "Arctic Monkeys",
                "Favourite Worst Nightmare (Standard Version)",
                "Favourite Worst Nightmare",
            ),
            ("R.E.M.", "Out Of Time (25th Anniversary Edition)", "Out Of Time"),
            ("Young the Giant", "Young The Giant (Special Edition)", "Young The Giant"),
            ("Beyoncé", "Renaissance (Deluxe)", "Renaissance"),
        )
        for artist, album, retrieval_title in fixtures:
            with self.subTest(album=album):
                queries = matcher.plan_queries(album, artist)
                self.assertEqual(queries[1]["query"], f"{retrieval_title} {artist}")
                self.assertEqual(queries[0]["query"], f"{album} {artist}")
        self.assertEqual(
            matcher.strip_retrieval_qualifiers("Album (Notes From Home)"),
            "Album (Notes From Home)",
        )

    def test_normalization_keeps_token_boundaries_and_numeric_titles(self):
        self.assertEqual(
            matcher.normalize("Beyoncé—RÉNAISSANCE"), "beyonce renaissance"
        )
        self.assertEqual(
            matcher.normalize("Beyoncé_RÉNAISSANCE"), "beyonce renaissance"
        )
        self.assertEqual(matcher.normalize("Vol. 2"), "vol 2")
        self.assertNotEqual(matcher.normalize("12 3"), matcher.normalize("123"))

    def test_sparse_parser_marks_multiple_delimiters_ambiguous(self):
        self.assertEqual(
            matcher.parse_sparse_candidate({"id": "1", "desc": "25 by Adele"})[
                "fields"
            ],
            {"title": "25", "artist": "Adele"},
        )
        parsed = matcher.parse_sparse_candidate(
            {"id": "by", "desc": "By the Way by The Red By Band"}
        )
        self.assertEqual(
            parsed["fields"], {"title": "By the Way by The Red", "artist": "Band"}
        )
        self.assertTrue(parsed["ambiguous"])
        self.assertEqual(
            matcher.parse_sparse_candidate({"id": "2", "desc": "unstructured"})[
                "fields"
            ],
            {},
        )

    def test_wrong_artist_same_title_and_sparse_evidence_are_not_recommended(self):
        source = {**SOURCE, "album": "25", "artist": "Adele"}
        ranked, recommendation = matcher.rank_candidates(
            source, [{"id": "wrong", "desc": "25 by Someone Else"}]
        )
        self.assertEqual(ranked[0]["score"]["title"], 60)
        self.assertIsNone(recommendation)
        ranked, recommendation = matcher.rank_candidates(
            source, [{"id": "sparse", "desc": "25"}]
        )
        self.assertEqual(ranked[0]["score"]["evidence_state"], "insufficient_evidence")
        self.assertIsNone(recommendation)

    def test_edition_vetoes(self):
        for album, desc, veto in (
            ("Album (Live)", "Album (Studio) by Artist", "live_studio_conflict"),
            ("Album (Remastered)", "Album by Artist", "remaster_conflict"),
            ("Album (Explicit)", "Album (Clean) by Artist", "clean_explicit_conflict"),
            ("Album", "Album (Karaoke) by Artist", "karaoke_conflict"),
        ):
            with self.subTest(veto=veto):
                ranked, recommendation = matcher.rank_candidates(
                    {**SOURCE, "album": album, "artist": "Artist"},
                    [{"id": veto, "desc": desc}],
                )
                self.assertIn(veto, ranked[0]["vetoes"])
                self.assertIsNone(recommendation)

    def test_ranking_margin_and_conservative_recommendation(self):
        source = {**SOURCE, "album": "Renaissance", "artist": "Beyoncé"}
        ranked, recommendation = matcher.rank_candidates(
            source,
            [
                {"id": "b", "desc": "Renaissance by Beyoncé"},
                {"id": "a", "desc": "Renaissance by Beyoncé"},
            ],
        )
        self.assertEqual([item["id"] for item in ranked], ["a", "b"])
        self.assertIsNone(recommendation)
        ranked, recommendation = matcher.rank_candidates(
            source,
            [
                {"id": "good", "desc": "Renaissance by Beyoncé"},
                {"id": "bad", "desc": "Renaissance by Other"},
            ],
        )
        self.assertEqual(
            recommendation,
            {
                "qobuz_id": "good",
                "score": 90,
                "margin": 30,
                "kind": "conservative_sparse",
            },
        )

    def test_ambiguity_alone_withholds_an_otherwise_positive_recommendation(self):
        source = {**SOURCE, "album": "By the Way by The Red", "artist": "Band"}
        candidate = {"id": "ambiguous", "desc": "By the Way by The Red by Band"}
        parsed = matcher.parse_sparse_candidate(candidate)
        self.assertEqual(
            parsed["fields"], {"title": source["album"], "artist": source["artist"]}
        )
        self.assertTrue(parsed["ambiguous"])
        ranked = matcher.score_candidate(source, parsed)
        self.assertEqual(ranked["score"]["total"], 90)
        record = matcher.build_record(
            self.request(source=source, candidates=[candidate])
        )
        self.assertIsNone(record["recommended_candidate"])
        self.assertEqual(
            record["recommendation_withheld_reasons"], ["ambiguous_display_parsing"]
        )

    def test_exact_artist_guard_withholds_reordered_high_score_artist(self):
        source = {**SOURCE, "album": "Album (Live)", "artist": "Red Hot Chili Peppers"}
        candidate = {"id": "reordered", "desc": "Album (Live) by Chili Peppers Red Hot"}
        ranked = matcher.score_candidate(
            source, matcher.parse_sparse_candidate(candidate)
        )
        self.assertEqual(ranked["score"]["title"], 60)
        self.assertEqual(ranked["score"]["edition"], 10)
        self.assertGreaterEqual(ranked["score"]["total"], 90)
        record = matcher.build_record(
            self.request(source=source, candidates=[candidate])
        )
        self.assertIsNone(record["recommended_candidate"])
        self.assertEqual(
            record["recommendation_withheld_reasons"], ["artist_not_exact"]
        )

    def test_incomplete_retrieval_changes_only_one_positive_guard_at_a_time(self):
        source = {**SOURCE, "album": "Renaissance"}
        candidate = [{"id": "good", "desc": "Renaissance by Beyoncé"}]
        baseline = self.request(source=source, candidates=candidate)
        self.assertEqual(
            matcher.build_record(baseline)["recommended_candidate"],
            {
                "qobuz_id": "good",
                "score": 90,
                "margin": 90,
                "kind": "conservative_sparse",
            },
        )
        for override, reason in (
            ({"budget_truncated": True}, "retrieval_truncated"),
            ({"global_budget_incomplete": True}, "global_budget_incomplete"),
            (
                {
                    "query_stages": [
                        {
                            "stage": "x",
                            "query": "q",
                            "outcome": "command_failure",
                            "result_count": 0,
                            "unique_candidate_count": 0,
                        }
                    ]
                },
                "query_command_failure",
            ),
            (
                {
                    "query_stages": [
                        {
                            "stage": "x",
                            "query": "q",
                            "outcome": "timeout",
                            "result_count": 0,
                            "unique_candidate_count": 0,
                        }
                    ]
                },
                "query_timeout",
            ),
            (
                {
                    "query_stages": [
                        {
                            "stage": "x",
                            "query": "q",
                            "outcome": "malformed_response",
                            "result_count": 0,
                            "unique_candidate_count": 0,
                        }
                    ]
                },
                "query_malformed_response",
            ),
        ):
            with self.subTest(reason=reason):
                record = matcher.build_record({**baseline, **override})
                self.assertIsNone(record["recommended_candidate"])
                self.assertEqual(record["recommendation_withheld_reasons"], [reason])

    def test_pinned_streamrip_search_outcomes(self):
        valid = json.dumps(
            [
                {
                    "id": "id",
                    "desc": "Album by Artist",
                    "source": "qobuz",
                    "media_type": "album",
                }
            ]
        )
        for returncode, timed_out, output, expected in (
            (0, False, None, "empty"),
            (0, False, "[]", "empty"),
            (0, False, "", "malformed_response"),
            (0, False, "not json", "malformed_response"),
            (0, False, "{}", "malformed_response"),
            (1, False, valid, "command_failure"),
            (0, True, valid, "timeout"),
            (0, False, valid, "results"),
        ):
            with self.subTest(expected=expected, output=output):
                self.assertEqual(
                    matcher.classify_streamrip_search(returncode, timed_out, output),
                    expected,
                )

    def test_query_and_candidate_bounds_and_canonical_order(self):
        stages = [
            {
                "stage": str(index),
                "query": str(index),
                "outcome": "empty",
                "result_count": 0,
                "unique_candidate_count": 0,
            }
            for index in range(matcher.MAX_QUERY_STAGES + 1)
        ]
        with self.assertRaises(matcher.EvidenceError):
            matcher.build_record(self.request(query_stages=stages))
        candidates = [
            {"id": str(index), "desc": f"Album {index} by Artist"}
            for index in range(matcher.MAX_CANDIDATES + 1)
        ]
        with self.assertRaises(matcher.EvidenceError):
            matcher.build_record(self.request(candidates=candidates))
        second = matcher.build_record(
            self.request(
                source={**SOURCE, "spotify_id": "second", "artist": "A", "album": "Z"}
            )
        )
        first = matcher.build_record(
            self.request(
                source={**SOURCE, "spotify_id": "first", "artist": "A", "album": "A"}
            )
        )
        self.assertEqual(
            [
                record["source"]["spotify_id"]
                for record in matcher.build_manifest([second, first])["records"]
            ],
            ["first", "second"],
        )

    def test_destination_validation_rejects_normalized_symlink_and_hardlink_collisions(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache = root / "cache.json"
            cache.write_bytes(b"cache bytes")
            before = cache.read_bytes()
            with self.assertRaises(matcher.EvidenceError):
                matcher.validate_evidence_destination(
                    str(root / "." / "cache.json"), [str(cache)]
                )
            self.assertEqual(cache.read_bytes(), before)
            alias_parent = root / "alias"
            alias_parent.symlink_to(root, target_is_directory=True)
            with self.assertRaises(matcher.EvidenceError):
                matcher.validate_evidence_destination(
                    str(alias_parent / "cache.json"), [str(cache)]
                )
            hardlink = root / "hardlink.json"
            os.link(cache, hardlink)
            with self.assertRaises(matcher.EvidenceError):
                matcher.validate_evidence_destination(str(hardlink), [str(cache)])
            with self.assertRaises(matcher.EvidenceError):
                matcher.validate_evidence_destination(str(root), [str(cache)])
            self.assertEqual(cache.read_bytes(), before)

    def _reporting_fixture(
        self, root, *, reporter_failure=None, publisher_failure=False, legacy_status=0
    ):
        report = root / "evidence.json"
        report.write_bytes(b"existing evidence report\n")
        requests = root / "requests.jsonl"
        requests.write_text(
            json.dumps(
                {
                    "source": {**SOURCE, "album": "Renaissance"},
                    "status": "selection_auto",
                }
            )
            + "\n",
            encoding="utf-8",
        )
        legacy = {}
        for name, content in {
            "selected": b'[{"id":"legacy-selected"}]\n',
            "cache": b'{"legacy":"cache"}\n',
            "manifest": b'[{"id":"legacy-selected"}]\n',
            "consent": b"legacy consent\n",
        }.items():
            path = root / name
            path.write_bytes(content)
            legacy[path] = content
        provider = root / "fake-provider.py"
        provider.write_text(
            "#!" + sys.executable + "\n"
            "import json, sys\n"
            "output = sys.argv[sys.argv.index('--output-file') + 1]\n"
            "with open(output, 'w', encoding='utf-8') as handle:\n"
            "    json.dump([{'id': 'evidence-id', 'desc': 'Renaissance by Beyoncé', 'source': 'qobuz', 'media_type': 'album'}], handle)\n",
            encoding="utf-8",
        )
        provider.chmod(0o700)
        reporter = root / "fake-reporter.py"
        reporter.write_text(
            "#!" + sys.executable + "\n"
            "import os, sys\n"
            "if os.environ.get('FAKE_REPORTER_FAILURE') == sys.argv[1]:\n"
            "    raise SystemExit(9)\n"
            "os.execv(sys.executable, [sys.executable, os.environ['MATCHER_PATH'], *sys.argv[1:]])\n",
            encoding="utf-8",
        )
        reporter.chmod(0o700)
        command = [
            sys.executable,
            str(Path(matcher.__file__)),
            "run-report",
            "--requests",
            str(requests),
            "--destination",
            str(report),
            "--provider",
            str(provider),
            "--reporter",
            str(reporter),
            "--legacy-exit-status",
            str(legacy_status),
        ]
        if publisher_failure:
            publisher = root / "fake-rename.py"
            publisher.write_text(
                "#!" + sys.executable + "\nimport sys\nraise SystemExit(8)\n",
                encoding="utf-8",
            )
            publisher.chmod(0o700)
            command.extend(["--publisher", str(publisher)])
        environment = {**os.environ, "MATCHER_PATH": str(Path(matcher.__file__))}
        if reporter_failure:
            environment["FAKE_REPORTER_FAILURE"] = reporter_failure
        result = subprocess.run(
            command,
            text=True,
            capture_output=True,
            env=environment,
            check=False,
        )
        return result, report, legacy

    def test_executable_reporting_path_preserves_legacy_outputs_despite_conflicting_recommendation(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            result, report, legacy = self._reporting_fixture(Path(temporary))
            self.assertEqual(result.returncode, 0, result.stderr)
            published = json.loads(report.read_text(encoding="utf-8"))
            self.assertEqual(
                published["records"][0]["recommended_candidate"]["qobuz_id"],
                "evidence-id",
            )
            for path, before in legacy.items():
                self.assertEqual(path.read_bytes(), before)

    def test_executable_reporting_failures_preserve_existing_report_and_legacy_outputs(
        self,
    ):
        for reporter_failure, publisher_failure in (
            ("queries", False),
            ("record", False),
            (None, True),
        ):
            with (
                self.subTest(
                    reporter_failure=reporter_failure,
                    publisher_failure=publisher_failure,
                ),
                tempfile.TemporaryDirectory() as temporary,
            ):
                result, report, legacy = self._reporting_fixture(
                    Path(temporary),
                    reporter_failure=reporter_failure,
                    publisher_failure=publisher_failure,
                )
                self.assertEqual(result.returncode, 0)
                self.assertEqual(report.read_bytes(), b"existing evidence report\n")
                self.assertIn("preserving previous evidence report", result.stderr)
                for path, before in legacy.items():
                    self.assertEqual(path.read_bytes(), before)

    def test_post_download_reporting_preserves_the_download_failure_status(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            download = root / "fake-download.py"
            download.write_text(
                "#!" + sys.executable + "\nraise SystemExit(37)\n", encoding="utf-8"
            )
            download.chmod(0o700)
            download_result = subprocess.run([str(download)], check=False)
            self.assertEqual(download_result.returncode, 37)
            result, report, legacy = self._reporting_fixture(
                root,
                reporter_failure="manifest",
                legacy_status=download_result.returncode,
            )
            self.assertEqual(result.returncode, 37)
            self.assertEqual(report.read_bytes(), b"existing evidence report\n")
            for path, before in legacy.items():
                self.assertEqual(path.read_bytes(), before)

    def test_representative_current_unmatched_records(self):
        # Current unmatched records are fixtures only; catalog availability is
        # intentionally not asserted.
        for spotify_id, artist, album in (
            (
                "arctic-monkeys",
                "Arctic Monkeys",
                "Favourite Worst Nightmare (Standard Version)",
            ),
            ("rem", "R.E.M.", "Out Of Time (25th Anniversary Edition)"),
            ("young-the-giant", "Young the Giant", "Young The Giant (Special Edition)"),
            ("1Xq5CqbX72kc90sB2OWaLk", "Blue Rain Boots", "2023"),
        ):
            with self.subTest(album=album):
                self.assertTrue(matcher.plan_queries(album, artist))
                record = matcher.build_record(
                    self.request(
                        source={
                            **SOURCE,
                            "spotify_id": spotify_id,
                            "album": album,
                            "artist": artist,
                        }
                    )
                )
                matcher.validate_record(record)

    def test_stable_serialization_and_rejects_malformed_records(self):
        record = matcher.build_record(
            self.request(candidates=[{"id": "1", "desc": "Renaissance by Beyoncé"}])
        )
        manifest = matcher.build_manifest([record])
        self.assertEqual(
            matcher.serialize(manifest),
            matcher.serialize(matcher.build_manifest([record])),
        )
        with self.assertRaises(matcher.EvidenceError):
            matcher.build_record(self.request(candidates=[{"id": "", "desc": "bad"}]))
        with self.assertRaises(matcher.EvidenceError):
            matcher.build_record(self.request(query_stages=[{"stage": "x"}]))
        with self.assertRaises(matcher.EvidenceError):
            matcher.build_manifest([record, record])

    def test_cli_manifest_is_canonical(self):
        record = matcher.build_record(self.request())
        stdin, stdout = io.StringIO(json.dumps([record])), io.StringIO()
        with patch("sys.stdin", stdin), patch("sys.stdout", stdout):
            self.assertEqual(matcher.main(["manifest"]), 0)
        self.assertEqual(
            json.loads(stdout.getvalue()), matcher.build_manifest([record])
        )

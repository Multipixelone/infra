import json
import shutil
import signal
import struct
import tempfile
import threading
import time
import unittest
from dataclasses import replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from typing import ClassVar
from unittest.mock import patch

import openclaw_music.deadline as deadline_module
import openclaw_music.resolver as resolver_module
import openclaw_music.slskd as slskd_module
from openclaw_music.config import TrustedConfig, production_factory
from openclaw_music.deadline import (
    DeadlineExpired,
    absolute_deadline,
    closing_create_connection,
)
from openclaw_music.errors import (
    BackendNotFound,
    BackendPermanent,
    BackendTransient,
    BackendUncertain,
    Configuration,
    Conflict,
    InvalidInput,
)
from openclaw_music.importer import DirectBeetsImportAdapter
from openclaw_music.jobs import JobService
from openclaw_music.resolver import MusicBrainzClient, latest_groups
from openclaw_music.slskd import (
    HttpTransport,
    SlskdClient,
    normalize_transfers,
    rank_offers,
    source_offers,
    transfer_succeeded,
)
from openclaw_music.validation import (
    AudioValidator,
    expected_batch_relative,
    expected_completed_relative,
    slskd_sanitized,
)


def wav() -> bytes:
    samples = b"\x00\x00" * 800
    header = (
        b"RIFF"
        + struct.pack("<I", 36 + len(samples))
        + b"WAVEfmt "
        + struct.pack("<IHHIIHH", 16, 1, 1, 8000, 16000, 2, 16)
    )
    return header + b"data" + struct.pack("<I", len(samples)) + samples


class MB:
    def __call__(self, path):
        if path.startswith("/artist/"):
            return {
                "artists": [
                    {"id": "a1", "name": "Artist"},
                    {"id": "a2", "name": "Artist"},
                ]
            }
        if path.startswith("/release-group/"):
            return {
                "release-groups": [
                    {"id": "g1", "title": "Album"},
                    {"id": "g2", "title": "Album"},
                ]
            }
        if path.startswith("/release/r"):
            release = path.split("?")[0].split("/")[-1]
            return {
                "id": release,
                "title": "Album",
                "status": "Official",
                "media": [
                    {
                        "position": 1,
                        "format": "CD",
                        "tracks": [
                            {
                                "position": 1,
                                "number": "1",
                                "title": "One",
                                "recording": {"id": "rec1", "length": 200},
                            },
                            {
                                "position": 2,
                                "number": "2",
                                "title": "Two",
                                "recording": {"id": "rec2", "length": 200},
                            },
                        ],
                    }
                ],
            }
        return {
            "releases": [
                {
                    "id": "r1",
                    "title": "Album",
                    "status": "Official",
                    "date": "2020-01-01",
                    "country": "US",
                    "media": [{"format": "CD", "tracks": [{}, {}]}],
                },
                {
                    "id": "r2",
                    "title": "Album",
                    "status": "Official",
                    "date": "2020-01-02",
                    "country": "GB",
                    "media": [{"format": "CD", "tracks": [{}, {}]}],
                },
            ]
        }


class SlskdFixture:
    def __init__(self, root):
        self.root = root
        self.search_polls = 0
        self.search_id = None
        self.search_created = False
        self.search_posts = 0
        self.lose_search_response = False
        self.queued = 0
        self.deleted = 0
        self.batch_id = None

    def __call__(self, method, path, body=None):
        if method == "POST" and path == "/api/v0/searches":
            payload = json.loads(body)
            assert payload["searchText"] == "Artist Album"
            self.search_id = payload["id"]
            self.search_created = True
            self.search_posts += 1
            if self.lose_search_response:
                raise BackendUncertain("lost response")
            return {"id": self.search_id, "state": "InProgress"}
        if (
            method == "GET"
            and path.startswith("/api/v0/searches/")
            and not path.endswith("/responses")
        ):
            if path.rsplit("/", 1)[-1] != self.search_id or not self.search_created:
                raise BackendNotFound("missing")
            self.search_polls += 1
            return {
                "id": self.search_id,
                "state": "Completed" if self.search_polls > 1 else "InProgress",
            }
        if method == "GET" and path.endswith("/responses"):
            return [
                {
                    "username": "peer",
                    "hasFreeUploadSlot": True,
                    "queueLength": 0,
                    "uploadSpeed": 20,
                    "files": [
                        {
                            "filename": "Album\\01 - One.wav",
                            "size": len(wav()),
                            "extension": "wav",
                            "isLocked": False,
                        },
                        {
                            "filename": "Album\\02 - Two.wav",
                            "size": len(wav()),
                            "extension": "wav",
                            "isLocked": False,
                        },
                    ],
                    "lockedFiles": [],
                }
            ]
        if method == "DELETE":
            self.deleted += 1
            return None
        if method == "POST" and path == "/api/v0/transfers/downloads/batches":
            payload = json.loads(body)
            assert payload["username"] == "peer"
            assert payload["searchId"] == self.search_id
            assert payload["options"] == {
                "destination": f"openclaw/{payload['id']}",
                "externalId": payload["id"],
            }
            assert payload["files"] == [
                {"filename": "Album\\01 - One.wav", "size": len(wav())},
                {"filename": "Album\\02 - Two.wav", "size": len(wav())},
            ]
            self.queued += 1
            self.batch_id = payload["id"]
            folder = self.root / "openclaw" / payload["id"]
            folder.mkdir(parents=True)
            (folder / "01 - One.wav").write_bytes(wav())
            (folder / "02 - Two.wav").write_bytes(wav())
            return None
        if method == "GET" and path == "/api/v0/transfers/downloads":
            if not self.queued:
                return []
            future = "2999-01-01T00:00:00Z"
            return [
                {
                    "username": "peer",
                    "directories": [
                        {
                            "directory": "unused",
                            "files": [
                                {
                                    "id": "t2",
                                    "filename": "Album\\02 - Two.wav",
                                    "size": len(wav()),
                                    "state": "Completed, Succeeded",
                                    "bytesTransferred": len(wav()),
                                    "requestedAt": future,
                                    "completedAt": future,
                                    "batchId": self.batch_id,
                                },
                                {
                                    "id": "t1",
                                    "filename": "Album\\01 - One.wav",
                                    "size": len(wav()),
                                    "state": "Completed, Succeeded",
                                    "bytesTransferred": len(wav()),
                                    "requestedAt": future,
                                    "completedAt": future,
                                    "batchId": self.batch_id,
                                },
                            ],
                        }
                    ],
                }
            ]
        raise AssertionError((method, path))

    @staticmethod
    def assert_body(body, expected):
        assert json.loads(body) == expected


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.download = root / "downloads"
        self.download.mkdir()
        self.library = root / "library"
        self.library.mkdir()
        secret = root / "secret"
        secret.write_text("SLSKD_API_KEY=key\n")
        self.config = TrustedConfig(
            str(root / "ledger"),
            str(root / "stage"),
            str(self.download),
            "tests/1 (test@example.invalid)",
            "http://127.0.0.1:5030",
            str(secret),
            shutil.which("ffprobe"),
            shutil.which("ffmpeg"),
            transport_isolated=True,
            library_root=str(self.library),
        )
        self.slskd = SlskdFixture(self.download)
        self.service = production_factory(
            self.config, mb_transport=MB(), slskd_transport=self.slskd
        )

    def tearDown(self):
        self.directory.cleanup()

    def choose_current(self):
        current = self.service.worker_once()["candidate_set"]
        return self.service.choose(
            self.job["job_id"],
            current["id"],
            current["candidates"][0]["id"],
            current["revision"],
        )

    def test_production_factory_strict_journey_reaches_ready(self):
        self.job = self.service.submit(
            {
                "idempotency_key": "one",
                "artist": "Artist",
                "release": "Album",
                "quality_profile": "lossless-preferred",
            }
        )
        self.service.worker_once()
        self.choose_current()
        self.choose_current()
        self.choose_current()
        result = None
        for _ in range(30):
            result = self.service.worker_once()
            if result["state"] == "ready":
                break
        self.assertEqual(result["state"], "ready")
        self.assertEqual(result["track_count"], 2)
        self.assertEqual(result["resolved_release"]["track_count"], 2)
        self.assertNotIn("tracks", result["resolved_release"])
        self.assertNotIn("details", result["resolved_release"])
        self.assertEqual(self.slskd.queued, 1)
        self.assertEqual(self.slskd.deleted, 1)

    def test_search_lost_post_response_recovers_by_persisted_uuid_without_replay(self):
        self.job = self.service.submit(
            {
                "idempotency_key": "lost-search",
                "artist": "Artist",
                "release": "Album",
                "quality_profile": "lossless-preferred",
            }
        )
        self.service.worker_once()
        self.choose_current()
        self.choose_current()
        self.choose_current()
        self.service.worker_once()  # resolve to searching
        self.service.worker_once()  # persist UUID intent
        self.service.worker_once()  # GET 404, proven not started
        self.slskd.lose_search_response = True
        self.assertEqual(self.service.worker_once()["state"], "searching")
        self.assertEqual(self.slskd.search_posts, 1)
        self.assertEqual(self.service.worker_once()["state"], "searching")
        self.assertEqual(self.slskd.search_posts, 1)

    def test_nonexact_release_choice_advances_without_repeating_group_set(self):
        self.job = self.service.submit(
            {
                "idempotency_key": "nonexact",
                "artist": "Artist",
                "release": "Albu",
                "quality_profile": "lossless",
            }
        )
        self.service.worker_once()
        self.choose_current()
        group_set = self.service.worker_once()["candidate_set"]
        self.assertEqual(group_set["stage"], "release_group")
        group = group_set["candidates"][0]
        chosen = self.service.choose(
            self.job["job_id"], group_set["id"], group["id"], group_set["revision"]
        )
        self.assertEqual(chosen["state"], "resolving")
        repeated = self.service.choose(
            self.job["job_id"], group_set["id"], group["id"], group_set["revision"]
        )
        self.assertEqual(repeated["state"], "resolving")
        edition_set = self.service.worker_once()["candidate_set"]
        self.assertEqual(edition_set["stage"], "edition")

    def test_isolation_blocks_before_queue_and_new_factory_resumes(self):
        blocked_config = replace(self.config, transport_isolated=False)
        blocked = production_factory(
            blocked_config, mb_transport=MB(), slskd_transport=self.slskd
        )
        job = blocked.submit(
            {
                "idempotency_key": "isolation",
                "artist": "Artist",
                "release": "Album",
                "quality_profile": "lossless",
            }
        )
        blocked.worker_once()
        for _ in range(3):
            choice = blocked.worker_once()["candidate_set"]
            blocked.choose(
                job["job_id"],
                choice["id"],
                choice["candidates"][0]["id"],
                choice["revision"],
            )
        for _ in range(10):
            status = blocked.worker_once()
            if status["integration_required"]:
                break
        self.assertEqual(status["state"], "searching")
        self.assertEqual(self.slskd.queued, 0)
        resumed = production_factory(
            self.config, mb_transport=MB(), slskd_transport=self.slskd
        )
        self.assertEqual(resumed.worker_once()["state"], "searching")
        self.assertEqual(resumed.worker_once()["state"], "downloading")
        self.assertEqual(self.slskd.queued, 0)

    def test_musicbrainz_short_page_with_count_continues(self):
        offsets = []

        def transport(path):
            offsets.append(path)
            if "offset=0" in path:
                return {"artists": [{"id": "one"}], "artist-count": 2}
            return {"artists": [{"id": "two"}], "artist-count": 2}

        client = MusicBrainzClient(
            "tests/1",
            transport=transport,
            limiter=type("Limiter", (), {"wait": lambda self: None})(),
        )
        self.assertEqual(
            [artist["id"] for artist in client.artists("Artist")], ["one", "two"]
        )
        self.assertEqual(len(offsets), 2)

    def test_candidate_projection_and_cap_are_safe(self):
        job = self.service.submit(
            {
                "idempotency_key": "candidate-cap",
                "artist": "Artist",
                "release": "Album",
                "quality_profile": "lossless",
            }
        )
        self.service.worker_once()
        first = self.service.worker_once()["candidate_set"]["candidates"][0]
        self.assertIn("name", first)
        self.assertIn("mbid", first)
        with self.service.ledger.locked():
            stored = self.service.ledger.get(job["job_id"])
            self.service._candidate_set(
                stored,
                "artist",
                [
                    {
                        "label": "Artist",
                        "reason": "many",
                        "entity": {"id": str(index), "name": "Artist"},
                    }
                    for index in range(21)
                ],
            )
            self.service.ledger.save(stored)
        status = self.service.status(job["job_id"])
        self.assertEqual(status["state"], "needs_review")
        self.assertEqual(status["error"]["code"], "too_many_candidates")

    def test_omitted_quality_fingerprint_survives_default_change(self):
        request = {
            "idempotency_key": "default-change",
            "artist": "Artist",
            "release": "Album",
        }
        first = self.service.submit(request)
        changed = production_factory(
            replace(self.config, quality_default="lossless"),
            mb_transport=MB(),
            slskd_transport=self.slskd,
        )
        repeated = changed.submit(request)
        self.assertEqual(first["job_id"], repeated["job_id"])
        self.assertEqual(
            changed.ledger.get(first["job_id"])["policy"]["profile"],
            "lossless-preferred",
        )

    def test_completed_without_succeeded_is_not_success(self):
        self.assertFalse(transfer_succeeded("Completed"))
        records = normalize_transfers(
            [
                {
                    "username": "p",
                    "directories": [
                        {
                            "files": [
                                {
                                    "id": "x",
                                    "filename": "A\\1.wav",
                                    "size": 1,
                                    "state": "Completed",
                                    "requestedAt": "2999-01-01T00:00:00Z",
                                    "exception": "  backend\nreason  ",
                                }
                            ]
                        }
                    ],
                }
            ]
        )
        self.assertEqual(records[0]["remote"], "A/1.wav")
        self.assertEqual(records[0]["exception"], "backend reason")

    def _submitted_transfer_job(self, key):
        job = self.service.submit(
            {
                "idempotency_key": key,
                "artist": "Artist",
                "release": "Album",
                "quality_profile": "lossless",
            }
        )
        files = [
            {"peer": "peer", "remote": "Album/01.wav", "size": 10},
            {"peer": "peer", "remote": "Album/02.wav", "size": 20},
        ]
        with self.service.ledger.locked():
            stored = self.service.ledger.get(job["job_id"])
            stored["state"] = "downloading"
            stored["transfer_intent"] = {
                "status": "submitted",
                "cleanup": "done",
                "batch_id": job["job_id"],
                "requested_at": "2000-01-01T00:00:00+00:00",
                "files": files,
            }
            self.service.ledger.save(stored)
        records = []
        self.service.slskd = SimpleNamespace(transfers=lambda: records)
        return job, records

    def test_exact_zero_byte_transfer_rejections_are_terminal_and_actionable(self):
        job, records = self._submitted_transfer_job("zero-byte-rejected")
        job_id = job["job_id"]
        records.extend(
            [
                {
                    "peer": "peer",
                    "remote": "Album/01.wav",
                    "size": 10,
                    "id": "one",
                    "state": "Completed, Rejected",
                    "bytes": 0,
                    "timestamps": {"requestedAt": "2999-01-01T00:00:00+00:00"},
                    "batch_id": job_id,
                    "exception": "Overwhelmed with requests; try again later.",
                },
                {
                    "peer": "peer",
                    "remote": "Album/02.wav",
                    "size": 20,
                    "id": "two",
                    "state": "Completed, Rejected",
                    "bytes": 0,
                    "timestamps": {"requestedAt": "2999-01-01T00:00:00+00:00"},
                    "batch_id": job_id,
                    "exception": "Overwhelmed with requests; try again later.",
                },
            ]
        )

        result = self.service.worker_once()

        self.assertEqual(result["state"], "failed")
        self.assertFalse(result["retryable"])
        self.assertIsNone(result["resume_phase"])
        self.assertEqual(result["error"]["code"], "transfer_rejected")
        self.assertIn("Overwhelmed with requests", result["error"]["message"])
        self.assertIn("wait or change source", result["error"]["message"])
        self.assertIn("new idempotency key", result["error"]["message"])
        with self.assertRaises(Conflict):
            self.service.retry(job_id)

    def test_partial_byte_transfer_failure_remains_needs_review(self):
        job, records = self._submitted_transfer_job("partial-byte-rejected")
        job_id = job["job_id"]
        records.extend(
            [
                {
                    "peer": "peer",
                    "remote": "Album/01.wav",
                    "size": 10,
                    "id": "one",
                    "state": "Completed, Rejected",
                    "bytes": 1,
                    "timestamps": {"requestedAt": "2999-01-01T00:00:00+00:00"},
                    "batch_id": job_id,
                    "exception": "Overwhelmed with requests; try again later.",
                },
                {
                    "peer": "peer",
                    "remote": "Album/02.wav",
                    "size": 20,
                    "id": "two",
                    "state": "Completed, Rejected",
                    "bytes": 0,
                    "timestamps": {"requestedAt": "2999-01-01T00:00:00+00:00"},
                    "batch_id": job_id,
                    "exception": "Overwhelmed with requests; try again later.",
                },
            ]
        )

        result = self.service.worker_once()

        self.assertEqual(result["state"], "needs_review")
        self.assertFalse(result["retryable"])
        self.assertEqual(result["error"]["code"], "invalid_input")

    def test_zero_byte_non_rejected_transfer_failure_remains_needs_review(self):
        job, records = self._submitted_transfer_job("zero-byte-aborted")
        job_id = job["job_id"]
        records.extend(
            [
                {
                    "peer": "peer",
                    "remote": "Album/01.wav",
                    "size": 10,
                    "id": "one",
                    "state": "Completed, Aborted",
                    "bytes": 0,
                    "timestamps": {"requestedAt": "2999-01-01T00:00:00+00:00"},
                    "batch_id": job_id,
                    "exception": "connection interrupted",
                },
                {
                    "peer": "peer",
                    "remote": "Album/02.wav",
                    "size": 20,
                    "id": "two",
                    "state": "Completed, Aborted",
                    "bytes": 0,
                    "timestamps": {"requestedAt": "2999-01-01T00:00:00+00:00"},
                    "batch_id": job_id,
                    "exception": "connection interrupted",
                },
            ]
        )

        result = self.service.worker_once()

        self.assertEqual(result["state"], "needs_review")
        self.assertFalse(result["retryable"])
        self.assertEqual(result["error"]["code"], "invalid_input")

    def test_source_mapping_rejects_duplicate_and_wrong_tracks(self):
        tracks = [
            {"disc": 1, "track": 1, "title": "One"},
            {"disc": 1, "track": 2, "title": "Two"},
        ]
        rows = [
            {
                "peer": "p",
                "remote": "Album/01 - One.wav",
                "original_remote": "Album/01 - One.wav",
                "size": 1,
                "locked": False,
                "queue": 0,
                "free_slot": True,
                "speed": 1,
                "extension": "wav",
            },
            {
                "peer": "p",
                "remote": "Album/01 - Two.wav",
                "original_remote": "Album/01 - Two.wav",
                "size": 1,
                "locked": False,
                "queue": 0,
                "free_slot": True,
                "speed": 1,
                "extension": "wav",
            },
        ]
        offers = source_offers(rows, tracks)
        self.assertFalse(offers[0]["complete"])
        self.assertIsNone(rank_offers(offers, {"profile": "lossless"})[0])

    def test_source_prefix_does_not_strip_canonical_title_numbers(self):
        track = [{"disc": 1, "track": 1, "title": "99 Problems"}]
        common = {
            "peer": "p",
            "original_remote": "",
            "size": 1,
            "locked": False,
            "queue": 0,
            "free_slot": True,
            "speed": 1,
            "extension": "wav",
        }
        rejected = source_offers(
            [{**common, "remote": "Album/01 - Problems.wav"}], track
        )
        accepted = source_offers(
            [{**common, "remote": "Album/01 - 99 Problems.wav"}], track
        )
        self.assertFalse(rejected[0]["complete"])
        self.assertTrue(accepted[0]["complete"])

    def test_nested_remote_completed_path_uses_immediate_parent_only(self):
        self.assertEqual(
            expected_completed_relative("Library/Album/CD1/01 - One.wav"),
            Path("CD1/01 - One.wav"),
        )
        self.assertEqual(
            expected_completed_relative("Album/02 - Two.wav"),
            Path("Album/02 - Two.wav"),
        )

    def test_multidisc_cd_folders_form_one_exact_offer(self):
        tracks = [
            {"disc": 1, "track": 1, "title": "One"},
            {"disc": 2, "track": 1, "title": "Two"},
        ]
        rows = [
            {
                "peer": "p",
                "remote": "Album/CD1/01 - One.wav",
                "original_remote": "Album/CD1/01 - One.wav",
                "size": 1,
                "locked": False,
                "queue": 0,
                "free_slot": True,
                "speed": 1,
                "extension": "wav",
            },
            {
                "peer": "p",
                "remote": "Album/Disc 2/01 - Two.wav",
                "original_remote": "Album/Disc 2/01 - Two.wav",
                "size": 1,
                "locked": False,
                "queue": 0,
                "free_slot": True,
                "speed": 1,
                "extension": "wav",
            },
        ]
        offers = source_offers(rows, tracks)
        self.assertEqual(len(offers), 1)
        self.assertTrue(offers[0]["complete"])
        self.assertEqual(
            {(item["disc"], item["track"]) for item in offers[0]["files"]},
            {(1, 1), (2, 1)},
        )

    def test_latest_rejects_future_and_keeps_partial_ties_ambiguous(self):
        groups = [
            {"id": "old", "primary-type": "Album", "first-release-date": "2025-01-01"},
            {"id": "partial", "primary-type": "Album", "first-release-date": "2026"},
            {
                "id": "future",
                "primary-type": "Album",
                "first-release-date": "2027-01-01",
            },
        ]
        self.assertEqual(
            [
                item["id"]
                for item in latest_groups(
                    groups,
                    as_of="2026-09-12T00:00:00+00:00",
                    include_live=False,
                    include_compilations=False,
                )
            ],
            ["partial"],
        )

    def test_corrupt_audio_is_not_blessed_by_real_validator(self):
        stage = Path(self.directory.name) / "corrupt"
        stage.mkdir()
        (stage / "01-01.wav").write_bytes(b"not audio")
        validator = AudioValidator(shutil.which("ffprobe"), shutil.which("ffmpeg"))
        with self.assertRaises(InvalidInput):
            validator.validate(
                stage,
                [{"name": "01-01.wav", "size": 9}],
                {"profile": "lossless", "max_files": 2, "max_bytes": 100},
            )

    def test_choice_triple_is_idempotent_and_stale_choice_conflicts(self):
        job = self.service.submit(
            {
                "idempotency_key": "choices",
                "artist": "Artist",
                "release": "Album",
                "quality_profile": "lossless",
            }
        )
        self.service.worker_once()
        candidate_set = self.service.worker_once()["candidate_set"]
        accepted = candidate_set["candidates"][0]
        self.service.choose(
            job["job_id"],
            candidate_set["id"],
            accepted["id"],
            candidate_set["revision"],
        )
        repeated = self.service.choose(
            job["job_id"],
            candidate_set["id"],
            accepted["id"],
            candidate_set["revision"],
        )
        self.assertEqual(repeated["state"], "resolving")
        with self.assertRaises(Conflict):
            self.service.choose(
                job["job_id"],
                candidate_set["id"],
                candidate_set["candidates"][1]["id"],
                candidate_set["revision"],
            )

    def test_import_reconcile_and_index_retry_are_durable(self):
        self.job = self.service.submit(
            {
                "idempotency_key": "import",
                "artist": "Artist",
                "release": "Album",
                "quality_profile": "lossless-preferred",
            }
        )
        self.service.worker_once()
        self.choose_current()
        self.choose_current()
        self.choose_current()
        for _ in range(30):
            if self.service.worker_once()["state"] == "ready":
                break
        library = self.library

        class Importer:
            behavior_identity = "phase2-test"
            calls = 0
            complete = False

            def reconcile_import(self, identity):
                if not self.complete:
                    return "not_started", None
                return "complete", {
                    **identity,
                    "receipt_id": "receipt",
                    "album_id": "album",
                    "items": [
                        {
                            "id": "one",
                            "source_name": "01-01.wav",
                            "final_path": str(library / "one.wav"),
                        },
                        {
                            "id": "two",
                            "source_name": "01-02.wav",
                            "final_path": str(library / "two.wav"),
                        },
                    ],
                    "final_paths": [str(library / "one.wav"), str(library / "two.wav")],
                    "success": True,
                }

            def import_album(self, plan, identity):
                self.calls += 1
                self.complete = True
                return self.reconcile_import(identity)[1]

        class Indexer:
            calls = 0

            def index(self, receipt):
                self.calls += 1
                return {"success": self.calls > 1}

        importer, indexer = Importer(), Indexer()
        self.service.importer = importer
        self.service.indexer = indexer
        self.assertEqual(self.service.worker_once()["state"], "importing")
        self.assertEqual(self.service.worker_once()["state"], "indexing")
        self.assertEqual(importer.calls, 1)
        self.assertEqual(self.service.worker_once()["state"], "failed")
        self.assertEqual(self.service.retry(self.job["job_id"])["state"], "indexing")
        self.assertEqual(self.service.worker_once()["state"], "succeeded")

    def test_ready_reconciles_complete_import_without_mutation(self):
        self.job = self.service.submit(
            {
                "idempotency_key": "complete-import",
                "artist": "Artist",
                "release": "Album",
                "quality_profile": "lossless-preferred",
            }
        )
        self.service.worker_once()
        self.choose_current()
        self.choose_current()
        self.choose_current()
        for _ in range(30):
            if self.service.worker_once()["state"] == "ready":
                break
        library = self.library

        class Importer:
            behavior_identity = "phase2-test"
            calls = 0

            def reconcile_import(self, identity):
                return "complete", {
                    **identity,
                    "receipt_id": "receipt",
                    "album_id": "album",
                    "items": [
                        {
                            "id": "one",
                            "source_name": "01-01.wav",
                            "final_path": str(library / "one.wav"),
                        },
                        {
                            "id": "two",
                            "source_name": "01-02.wav",
                            "final_path": str(library / "two.wav"),
                        },
                    ],
                    "final_paths": [str(library / "one.wav"), str(library / "two.wav")],
                    "success": True,
                }

            def import_album(self, plan, identity):
                self.calls += 1

        self.service.importer = Importer()
        self.service.indexer = type(
            "Indexer", (), {"index": lambda self, receipt: {"success": True}}
        )()
        self.assertEqual(self.service.worker_once()["state"], "indexing")
        self.assertEqual(self.service.importer.calls, 0)


class HttpTransportTests(unittest.TestCase):
    def setUp(self):
        self.requests = []
        requests = self.requests

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                requests.append(
                    (
                        self.path,
                        self.headers.get("X-API-Key"),
                        self.rfile.read(int(self.headers["Content-Length"])),
                    )
                )
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"id":"s"}')

            def do_DELETE(self):
                self.send_response(204)
                self.end_headers()

            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", "http://example.invalid/")
                self.end_headers()

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()

    def test_headers_json_empty_and_redirect_refusal(self):
        base = f"http://127.0.0.1:{self.server.server_port}"
        client = SlskdClient(base, "token", transport=HttpTransport(base, "token"))
        self.assertIsNone(client.create_search("s", "x"))
        client.delete_search("s")
        self.assertEqual(
            self.requests[0],
            ("/api/v0/searches", "token", b'{"id": "s", "searchText": "x"}'),
        )
        with self.assertRaises(BackendPermanent):
            client.search_status("s")

    def test_absolute_deadline_interrupts_dripping_headers_and_body(self):
        class DripHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/headers":
                    time.sleep(0.6)
                    self.send_response(200)
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header("Content-Length", "20")
                self.end_headers()
                for _ in range(10):
                    try:
                        self.wfile.write(b"x")
                        self.wfile.flush()
                    except BrokenPipeError:
                        return
                    time.sleep(0.1)

            def do_POST(self):
                self.do_GET()

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), DripHandler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            transport = HttpTransport(
                f"http://127.0.0.1:{server.server_port}", "token", deadline=0.2
            )
            for method, path, error in (
                ("GET", "/headers", BackendTransient),
                ("GET", "/body", BackendTransient),
                ("POST", "/body", BackendUncertain),
            ):
                started = time.monotonic()
                with self.subTest(method=method, path=path), self.assertRaises(error):
                    transport(method, path, b"{}" if method == "POST" else None)
                self.assertLess(time.monotonic() - started, 0.5)
            client = MusicBrainzClient(
                "tests/1",
                base_url=f"https://127.0.0.1:{server.server_port}/ws/2",
                deadline=0.2,
            )
            with patch.object(
                resolver_module.http.client,
                "HTTPSConnection",
                resolver_module.http.client.HTTPConnection,
            ):
                started = time.monotonic()
                with self.assertRaises(BackendTransient):
                    client._transport("/body")
                self.assertLess(time.monotonic() - started, 0.5)
        finally:
            server.shutdown()
            thread.join()
            server.server_close()

    def test_prearmed_alarm_is_preserved_when_deadline_guard_rejects_entry(self):
        fired = []
        previous_handler = signal.getsignal(signal.SIGALRM)
        previous_timer = signal.getitimer(signal.ITIMER_REAL)

        def handler(signum, frame):
            fired.append(True)

        try:
            signal.signal(signal.SIGALRM, handler)
            signal.setitimer(signal.ITIMER_REAL, 0.05)
            with self.assertRaises(Configuration), absolute_deadline(0.2):
                pass
            self.assertGreater(signal.getitimer(signal.ITIMER_REAL)[0], 0)
            time.sleep(0.1)
            self.assertTrue(fired)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous_handler)
            if previous_timer[0] or previous_timer[1]:
                signal.setitimer(signal.ITIMER_REAL, *previous_timer)

    def test_production_transports_close_response_and_connection(self):
        class Response:
            status = 200
            raise_on_read = None

            def __init__(self, body):
                self.body = body
                self.closed = False

            def read(self, size):
                if self.raise_on_read:
                    raise self.raise_on_read
                body, self.body = self.body, b""
                return body

            def close(self):
                self.closed = True

        class Connection:
            instances: ClassVar[list["Connection"]] = []
            response_body = b"{}"

            def __init__(self, *args, **kwargs):
                self.response = Response(self.response_body)
                self.closed = False
                type(self).instances.append(self)

            def request(self, *args, **kwargs):
                pass

            def getresponse(self):
                return self.response

            def close(self):
                self.closed = True

        with patch.object(slskd_module.http.client, "HTTPConnection", Connection):
            transport = HttpTransport("http://127.0.0.1:5030", "token")
            self.assertEqual(transport("GET", "/api/v0/test"), {})
            self.assertTrue(Connection.instances[-1].response.closed)
            self.assertTrue(Connection.instances[-1].closed)
            Response.raise_on_read = DeadlineExpired("test timeout")
            with self.assertRaises(BackendTransient):
                transport("GET", "/api/v0/test")
            self.assertTrue(Connection.instances[-1].response.closed)
            self.assertTrue(Connection.instances[-1].closed)
            Response.raise_on_read = None
        Connection.instances.clear()
        with patch.object(resolver_module.http.client, "HTTPSConnection", Connection):
            client = MusicBrainzClient(
                "tests/1", base_url="https://example.invalid/ws/2"
            )
            self.assertEqual(client._transport("/artist/"), {})
            self.assertTrue(Connection.instances[-1].response.closed)
            self.assertTrue(Connection.instances[-1].closed)

    def test_deadline_exception_cannot_be_swallowed_as_address_retry(self):
        attempts = []

        class MultiAddressConnection:
            def __init__(self, *args, **kwargs):
                self.closed = False

            def request(self, *args, **kwargs):
                attempts.append("first")
                try:
                    raise DeadlineExpired("expired")
                except OSError:
                    attempts.append("retry")

            def close(self):
                self.closed = True

        with patch.object(
            slskd_module.http.client, "HTTPConnection", MultiAddressConnection
        ):
            transport = HttpTransport("http://127.0.0.1:5030", "token")
            with self.assertRaises(BackendTransient):
                transport("GET", "/api/v0/test")
        self.assertEqual(attempts, ["first"])

    def test_socket_acquisition_closes_interrupted_candidates(self):
        class Candidate:
            def __init__(self, outcome):
                self.outcome = outcome
                self.closed = False

            def settimeout(self, timeout):
                pass

            def bind(self, source_address):
                pass

            def connect(self, sockaddr):
                if isinstance(self.outcome, BaseException):
                    raise self.outcome

            def close(self):
                self.closed = True

        class AcquiringConnection:
            def __init__(self, *args, **kwargs):
                self.closed = False

            def request(self, *args, **kwargs):
                self._create_connection(("example.invalid", 80), 1, None)

            def close(self):
                self.closed = True

        addresses = [(2, 1, 6, "", ("127.0.0.1", 80))]
        interrupted = Candidate(DeadlineExpired("interrupted connect"))
        with (
            patch.object(deadline_module.socket, "getaddrinfo", return_value=addresses),
            patch.object(deadline_module.socket, "socket", return_value=interrupted),
            patch.object(
                slskd_module.http.client, "HTTPConnection", AcquiringConnection
            ),
        ):
            transport = HttpTransport("http://127.0.0.1:5030", "token")
            with self.assertRaises(BackendTransient):
                transport("GET", "/api/v0/test")
            self.assertTrue(interrupted.closed)
        interrupted = Candidate(DeadlineExpired("interrupted connect"))
        with (
            patch.object(deadline_module.socket, "getaddrinfo", return_value=addresses),
            patch.object(deadline_module.socket, "socket", return_value=interrupted),
            patch.object(
                slskd_module.http.client, "HTTPConnection", AcquiringConnection
            ),
        ):
            transport = HttpTransport("http://127.0.0.1:5030", "token")
            with self.assertRaises(BackendUncertain):
                transport("POST", "/api/v0/test", b"{}")
            self.assertTrue(interrupted.closed)
        interrupted = Candidate(DeadlineExpired("interrupted connect"))
        with (
            patch.object(deadline_module.socket, "getaddrinfo", return_value=addresses),
            patch.object(deadline_module.socket, "socket", return_value=interrupted),
            patch.object(
                resolver_module.http.client, "HTTPSConnection", AcquiringConnection
            ),
        ):
            client = MusicBrainzClient(
                "tests/1", base_url="https://example.invalid/ws/2"
            )
            with self.assertRaises(BackendTransient):
                client._transport("/artist/")
            self.assertTrue(interrupted.closed)

        first = Candidate(OSError("first address failed"))
        second = Candidate(None)
        with (
            patch.object(
                deadline_module.socket, "getaddrinfo", return_value=addresses * 2
            ),
            patch.object(deadline_module.socket, "socket", side_effect=[first, second]),
        ):
            acquired = closing_create_connection(("example.invalid", 80), timeout=1)
        self.assertTrue(first.closed)
        self.assertIs(acquired, second)

    def test_direct_beets_adapter_uses_fixed_reconcile_argv(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            calls = []

            def runner(argv, **kwargs):
                calls.append((argv, kwargs))
                return SimpleNamespace(stdout="", stderr="", returncode=0)

            adapter = DirectBeetsImportAdapter(
                "/bin/true",
                str(root / "beets.yaml"),
                str(root / "lock"),
                str(root / "stage"),
                str(root / "library"),
                str(root),
                "/bin",
                str(root / "cache"),
                run=runner,
            )
            identity = {
                "job_id": "00000000-0000-0000-0000-000000000000",
                "release_mbid": "release",
                "manifest_digest": "a" * 64,
                "behavior": adapter.behavior_identity,
                "expected_tracks": [{"name": "01-01.flac", "disc": 1, "track": 1}],
                "policy": {"profile": "lossless-preferred"},
                "selected_quality": "lossless",
            }
            self.assertEqual(adapter.reconcile_import(identity), ("not_started", None))
            argv = calls[0][0]
            self.assertEqual(
                argv[:5], ["/bin/true", "-c", str(root / "beets.yaml"), "list", "-f"]
            )
            self.assertIn("openclaw_job_id:00000000-0000-0000-0000-000000000000", argv)
            self.assertEqual(calls[0][1]["env"], adapter.environment)

    def test_linux_batch_name_preserves_legal_punctuation_and_whitespace(self):
        name = "  ?legal:| name. "
        self.assertEqual(slskd_sanitized(name), name)
        self.assertEqual(
            expected_batch_relative(
                "00000000-0000-0000-0000-000000000000", "Album/" + name
            ).name,
            name,
        )

    def test_beets_nonzero_stops_for_review_even_with_correlated_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage" / "job"
            stage.mkdir(parents=True)
            library = root / "library"
            library.mkdir()
            final = library / "01.flac"
            final.write_bytes(b"audio")
            calls, job_queries = [], 0
            identity = {
                "job_id": "00000000-0000-0000-0000-000000000000",
                "release_mbid": "release",
                "manifest_digest": "a" * 64,
                "behavior": "openclaw-beets-cli-v1",
                "expected_tracks": [{"name": "01-01.flac", "disc": 1, "track": 1}],
                "policy": {"profile": "lossless"},
                "selected_quality": "lossless",
            }
            row = "|".join(
                [
                    "item",
                    "album",
                    "1",
                    "1",
                    "release",
                    str(final),
                    identity["job_id"],
                    identity["manifest_digest"],
                    identity["behavior"],
                ]
            )

            def runner(argv, **kwargs):
                nonlocal job_queries
                calls.append(argv)
                if "import" in argv:
                    return SimpleNamespace(stdout="", stderr="diagnostic", returncode=1)
                if argv[-1].startswith("openclaw_job_id:"):
                    job_queries += 1
                    return SimpleNamespace(
                        stdout="" if job_queries == 1 else row + "\n",
                        stderr="",
                        returncode=0,
                    )
                return SimpleNamespace(stdout="", stderr="", returncode=0)

            adapter = DirectBeetsImportAdapter(
                "/bin/true",
                str(root / "beets.yaml"),
                str(root / "lock"),
                str(root / "stage"),
                str(library),
                str(root),
                "/bin",
                str(root / "cache"),
                run=runner,
            )
            with self.assertRaises(BackendUncertain):
                adapter.import_album({"stage": str(stage)}, identity)
            import_calls = [argv for argv in calls if "import" in argv]
            self.assertEqual(len(import_calls), 1)
            self.assertIn("--quiet-fallback", import_calls[0])
            self.assertIn("skip", import_calls[0])

    def test_beets_receipt_measures_every_track_against_frozen_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = root / "library"
            library.mkdir()
            first, second = library / "one.flac", library / "two.flac"
            first.write_bytes(b"one")
            second.write_bytes(b"two")
            identity = {
                "job_id": "00000000-0000-0000-0000-000000000000",
                "release_mbid": "release",
                "manifest_digest": "a" * 64,
                "behavior": "openclaw-beets-cli-v1",
                "expected_tracks": [
                    {"name": "01-01.flac", "disc": 1, "track": 1},
                    {"name": "01-02.flac", "disc": 1, "track": 2},
                ],
                "policy": {"profile": "lossless"},
                "selected_quality": "lossless",
            }
            codecs = {"one.flac": "flac", "two.flac": "mp3"}
            validator = SimpleNamespace(
                inspect=lambda path: {"codec": codecs[path.name]}
            )
            adapter = DirectBeetsImportAdapter(
                "/bin/true",
                str(root / "beets.yaml"),
                str(root / "lock"),
                str(root / "stage"),
                str(library),
                str(root),
                "/bin",
                str(root / "cache"),
                validator=validator,
            )

            def rows():
                return [
                    {
                        "id": "one",
                        "album_id": "album",
                        "disc": "1",
                        "track": "1",
                        "mb_albumid": "release",
                        "path": str(first),
                        "openclaw_job_id": identity["job_id"],
                        "openclaw_manifest_digest": identity["manifest_digest"],
                        "openclaw_behavior": identity["behavior"],
                    },
                    {
                        "id": "two",
                        "album_id": "album",
                        "disc": "1",
                        "track": "2",
                        "mb_albumid": "release",
                        "path": str(second),
                        "openclaw_job_id": identity["job_id"],
                        "openclaw_manifest_digest": identity["manifest_digest"],
                        "openclaw_behavior": identity["behavior"],
                    },
                ]

            self.assertIsNone(
                adapter._receipt(identity, rows(), correlated=True)
            )  # mixed FLAC/MP3
            codecs["two.flac"] = "flac"
            self.assertIsNotNone(adapter._receipt(identity, rows(), correlated=True))
            codecs["one.flac"] = "aac"  # disguised extension is still rejected by codec
            self.assertIsNone(adapter._receipt(identity, rows(), correlated=True))
            identity["policy"] = {
                "profile": "lossless-preferred",
                "accepted_lossy": {"extensions": ["mp3"], "minimum_tracks": 2},
            }
            codecs["one.flac"] = "mp3"
            self.assertIsNotNone(adapter._receipt(identity, rows(), correlated=True))

    def test_batch_queue_route_partial_result_and_identity_are_strict(self):
        calls = []

        def transport(method, path, body=None):
            calls.append((method, path, json.loads(body)))

        client = SlskdClient("http://127.0.0.1:5030", "key", transport=transport)
        client.queue(
            "peer",
            [{"original_remote": "Album\\01.flac", "size": 1}],
            batch_id="batch",
            search_id="search",
        )
        self.assertEqual(calls[0][1], "/api/v0/transfers/downloads/batches")
        self.assertEqual(
            calls[0][2]["options"],
            {"destination": "openclaw/batch", "externalId": "batch"},
        )
        with self.assertRaises(BackendPermanent):
            SlskdClient(
                "http://127.0.0.1:5030",
                "key",
                transport=lambda *_: {
                    "batch": {"id": "batch"},
                    "failures": [{"filename": "one", "message": "no slot"}],
                },
            ).queue("peer", [], batch_id="batch", search_id="search")
        intent = {
            "batch_id": "batch",
            "requested_at": "2000-01-01T00:00:00+00:00",
            "files": [{"peer": "peer", "remote": "Album/01.flac", "size": 1}],
        }
        service = type(
            "Service",
            (),
            {
                "slskd": type(
                    "Transfers",
                    (),
                    {
                        "transfers": lambda _: [
                            {
                                "peer": "peer",
                                "remote": "Album/01.flac",
                                "size": 1,
                                "id": "x",
                                "state": "Completed, Succeeded",
                                "bytes": 1,
                                "timestamps": {
                                    "requestedAt": "2999-01-01T00:00:00+00:00"
                                },
                                "batch_id": None,
                                "external_id": None,
                            }
                        ]
                    },
                )()
            },
        )()
        self.assertEqual(
            JobService._reconcile_transfer(service, intent)[0], "needs_review"
        )

    def test_reconcile_ignores_only_foreign_zero_byte_rejections(self):
        intent = {
            "batch_id": "current",
            "requested_at": "2000-01-01T00:00:00+00:00",
            "files": [
                {"peer": "peer", "remote": "Album/01.flac", "size": 1},
                {"peer": "peer", "remote": "Album/02.flac", "size": 2},
            ],
        }
        future = "2999-01-01T00:00:00+00:00"

        def record(remote, size, transfer_id, state, bytes_transferred, batch_id):
            return {
                "peer": "peer",
                "remote": remote,
                "size": size,
                "id": transfer_id,
                "state": state,
                "bytes": bytes_transferred,
                "timestamps": {"requestedAt": future},
                "batch_id": batch_id,
            }

        current = [
            record(
                "Album/01.flac", 1, "current-one", "Completed, Succeeded", 1, "current"
            ),
            record(
                "Album/02.flac", 2, "current-two", "Completed, Succeeded", 2, "current"
            ),
        ]

        def reconcile(records):
            service = SimpleNamespace(slskd=SimpleNamespace(transfers=lambda: records))
            return JobService._reconcile_transfer(service, intent)[0]

        with self.subTest("foreign zero-byte rejected"):
            self.assertEqual(
                reconcile(
                    current
                    + [
                        record(
                            "Album/01.flac",
                            1,
                            "old-rejected",
                            "Completed, Rejected",
                            0,
                            "old",
                        )
                    ]
                ),
                "complete",
            )
        with self.subTest("foreign partial-byte rejected"):
            self.assertEqual(
                reconcile(
                    current
                    + [
                        record(
                            "Album/01.flac",
                            1,
                            "old-partial",
                            "Completed, Rejected",
                            1,
                            "old",
                        )
                    ]
                ),
                "needs_review",
            )
        with self.subTest("foreign successful"):
            self.assertEqual(
                reconcile(
                    current
                    + [
                        record(
                            "Album/01.flac",
                            1,
                            "old-success",
                            "Completed, Succeeded",
                            1,
                            "old",
                        )
                    ]
                ),
                "needs_review",
            )

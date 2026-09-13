from __future__ import annotations

import secrets
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .errors import (
    BackendNotFound,
    BackendUncertain,
    Conflict,
    InvalidInput,
    MusicError,
    Temporary,
    Unknown,
)
from .models import digest, new_job, now, touch, transition
from .slskd import (
    offer_pool,
    source_offers,
    state_flags,
    timestamp_after,
    transfer_failed,
    transfer_succeeded,
)
from .validation import capture, expected_batch_relative

MAX_PUBLIC_CANDIDATES = 20
MAX_PEER_ATTEMPTS = 5


def _bounded_text(value: object, limit: int = 160) -> str:
    return str(value or "")[:limit]


def _public_release(release: dict) -> dict:
    details = release.get("details") if isinstance(release.get("details"), dict) else {}
    media = details.get("media", [])
    formats = []
    if isinstance(media, list):
        formats = [
            str(item.get("format", ""))[:80]
            for item in media[:20]
            if isinstance(item, dict) and item.get("format")
        ]
    return {
        "mbid": release.get("mbid"),
        "title": _bounded_text(release.get("title")),
        "artist": _bounded_text(release.get("artist")),
        "date": details.get("date"),
        "country": details.get("country"),
        "media": formats,
        "track_count": len(release.get("tracks", [])),
    }


def public(job: dict, operation: str) -> dict:
    output = {
        "schema": 1,
        "operation": operation,
        "state": job["state"],
        "job_id": job["job_id"],
        "revision": job["revision"],
        "retryable": job.get("retryable", False),
        "resume_phase": job.get("resume_phase"),
        "integration_required": job.get("integration_required", False),
    }
    for key in (
        "selected_source",
        "selected_quality",
        "import_receipt",
        "mpd_result",
        "error",
        "final_library_path",
    ):
        if job.get(key) is not None:
            output[key] = job[key]
    if job.get("resolved_release"):
        output["resolved_release"] = _public_release(job["resolved_release"])
    if job.get("manifest"):
        output["track_count"] = len(job["manifest"])
    current = job.get("current_set")
    if current:
        candidate_set = job["candidate_sets"][current]
        output["candidate_set"] = candidate_set["public"]
        output["candidate_revision"] = candidate_set["revision"]
    return output


def _due(stamp: str | None) -> bool:
    return not stamp or stamp <= now()


def _zero_byte_rejected_transfer(record: dict) -> bool:
    return (
        state_flags(record["state"]) == {"completed", "rejected"}
        and type(record["bytes"]) is int
        and record["bytes"] == 0
    )


class JobService:
    def __init__(
        self, ledger, resolver, slskd, validator, config, *, importer=None, indexer=None
    ):
        self.ledger = ledger
        self.resolver = resolver
        self.slskd = slskd
        self.validator = validator
        self.config = config
        self.importer = importer
        self.indexer = indexer

    def submit(self, request: dict) -> dict:
        raw = {key: value for key, value in request.items() if value is not None}
        canonical = {
            key: value for key, value in raw.items() if key != "idempotency_key"
        }
        policy = {
            "profile": canonical.get("quality_profile", self.config.quality_default),
            "max_files": self.config.max_files,
            "max_bytes": self.config.max_bytes,
            "destination_mode": self.config.destination_mode,
        }
        with self.ledger.locked():
            existing = self.ledger.find_idempotency(raw["idempotency_key"])
            if existing:
                if existing["request_digest"] != digest(canonical):
                    raise Conflict("idempotency key was used for another request")
                return public(existing, "submit")
            job = new_job(raw, policy)
            job["as_of"] = now()
            self.ledger.save(job)
        return public(job, "submit")

    def status(self, job_id: str) -> dict:
        return public(self.ledger.get(job_id), "status")

    def retry(self, job_id: str) -> dict:
        with self.ledger.locked():
            job = self.ledger.get(job_id)
            phase = job.get("resume_phase")
            if (
                job["state"] != "failed"
                or not job.get("retryable")
                or phase
                not in {
                    "resolving",
                    "searching",
                    "downloading",
                    "validating",
                    "ready",
                    "indexing",
                }
            ):
                raise Conflict("job has no safe retry point")
            transition(job, phase)
            job["next_attempt_at"] = now()
            self.ledger.save(job)
        return public(job, "retry")

    def _commit(self, job: dict, revision: int) -> None:
        with self.ledger.locked():
            current = self.ledger.get(job["job_id"])
            if current["revision"] != revision:
                raise Temporary("job changed while worker was active")
            self.ledger.save(job)

    def _candidate_projection(self, stage: str, item: dict) -> dict:
        entity = item.get("entity") if isinstance(item.get("entity"), dict) else {}
        candidate = {
            "label": _bounded_text(item.get("label")),
            "reason": _bounded_text(item.get("reason")),
        }
        if stage == "artist":
            candidate.update(
                {
                    "name": _bounded_text(entity.get("name")),
                    "disambiguation": _bounded_text(entity.get("disambiguation")),
                    "mbid": entity.get("id"),
                }
            )
        elif stage == "release_group":
            types = entity.get("secondary-types", [])
            candidate.update(
                {
                    "title": _bounded_text(entity.get("title")),
                    "date": entity.get("first-release-date"),
                    "types": [str(value)[:40] for value in types[:10]]
                    if isinstance(types, list)
                    else [],
                    "mbid": entity.get("id"),
                }
            )
        elif stage == "edition":
            candidate.update(
                {
                    "title": _bounded_text(item.get("label")),
                    "date": item.get("date"),
                    "country": item.get("country"),
                    "status": item.get("status"),
                    "disambiguation": _bounded_text(item.get("disambiguation")),
                    "media": [str(value)[:80] for value in item.get("media", [])[:20]]
                    if isinstance(item.get("media"), list)
                    else [],
                    "track_count": item.get("track_count"),
                    "mbid": entity.get("id"),
                }
            )
        elif stage == "source_quality":
            offer = item.get("offer") if isinstance(item.get("offer"), dict) else {}
            candidate.update(
                {
                    "peer": _bounded_text(offer.get("peer")),
                    "quality": offer.get("quality"),
                    "free_slot": offer.get("free_slot"),
                    "queue": offer.get("queue"),
                    "speed": offer.get("speed"),
                    "file_count": len(offer.get("files", [])),
                    "track_count": len(offer.get("files", [])),
                }
            )
        return {
            key: value
            for key, value in candidate.items()
            if value is not None and value != ""
        }

    def _candidate_set(self, job: dict, stage: str, items: list[dict]) -> None:
        if len(items) > MAX_PUBLIC_CANDIDATES:
            transition(
                job,
                "needs_review",
                error={
                    "code": "too_many_candidates",
                    "message": "too many candidates; submit a narrower request",
                },
            )
            return
        set_id = secrets.token_urlsafe(18)
        public_items = []
        private = {}
        for item in items:
            candidate_id = secrets.token_urlsafe(18)
            private[candidate_id] = item
            public_items.append(
                {"id": candidate_id, **self._candidate_projection(stage, item)}
            )
        # The transition advances the revision once, so publish that exact revision in the immutable set.
        candidate_revision = job["revision"] + 1
        job["candidate_sets"][set_id] = {
            "stage": stage,
            "revision": candidate_revision,
            "public": {
                "id": set_id,
                "stage": stage,
                "revision": candidate_revision,
                "candidates": public_items,
            },
            "private": private,
        }
        job["current_set"] = set_id
        transition(job, "needs_choice")

    def choose(
        self, job_id: str, candidate_set_id: str, candidate_id: str, revision: int
    ) -> dict:
        with self.ledger.locked():
            job = self.ledger.get(job_id)
            candidate_set = job.get("candidate_sets", {}).get(candidate_set_id)
            if not candidate_set:
                raise Unknown("unknown candidate set")
            old = job.get("decisions", {}).get(candidate_set_id)
            if old is not None:
                if old == candidate_id and candidate_set["revision"] == revision:
                    return public(job, "choose")
                raise Conflict("different choice already accepted")
            if (
                job["state"] != "needs_choice"
                or job.get("current_set") != candidate_set_id
                or candidate_set["revision"] != revision
            ):
                raise Conflict("stale candidate choice")
            if candidate_id not in candidate_set["private"]:
                raise Unknown("unknown candidate")
            selected = candidate_set["private"][candidate_id]
            stage = candidate_set["stage"]
            job["decisions"][candidate_set_id] = candidate_id
            job["current_set"] = None
            if stage in {"artist", "release_group", "edition"}:
                job["selections"][stage] = selected["entity"]
                target = "resolving"
            elif stage == "source_quality":
                offer = selected["offer"]
                job["selected_offer"] = offer
                if not offer["all_lossless"]:
                    job["policy"]["accepted_lossy"] = {
                        "extensions": sorted(
                            {item["extension"] for item in offer["files"]}
                        ),
                        "minimum_tracks": len(offer["files"]),
                    }
                    job["policy_digest"] = digest(job["policy"])
                target = "searching"
            else:
                raise Conflict("unknown candidate stage")
            transition(job, target)
            self.ledger.save(job)
        return public(job, "choose")

    def _error(self, job: dict, revision: int, error: Exception) -> dict:
        with self.ledger.locked():
            current = self.ledger.get(job["job_id"])
        if current["revision"] != revision:
            job = current
            revision = current["revision"]
        if isinstance(error, BackendUncertain):
            transition(
                job,
                "needs_review",
                error={
                    "code": error.symbol,
                    "message": error.message[:240],
                    "retryable": False,
                    "resume_phase": None,
                    "manual_action": "inspect backend state before retrying",
                },
            )
        elif isinstance(error, MusicError) and error.retryable:
            attempts = int(job.get("attempts", 0)) + 1
            job["attempts"] = attempts
            job["retryable"] = True
            job["resume_phase"] = job["state"]
            job["error"] = {
                "code": error.symbol,
                "message": error.message[:240],
                "retryable": True,
                "resume_phase": job["state"],
            }
            job["next_attempt_at"] = (
                datetime.now(UTC) + timedelta(seconds=min(60, 2 ** min(attempts, 6)))
            ).isoformat()
            touch(job)
        else:
            transition(
                job,
                "needs_review",
                error={
                    "code": getattr(error, "symbol", "internal"),
                    "message": str(error)[:240],
                    "retryable": False,
                    "resume_phase": None,
                    "manual_action": "review the job ledger and adapter state",
                },
            )
        self._commit(job, revision)
        return public(job, "worker")

    def _select_job(self) -> tuple[dict, int] | None:
        with self.ledger.locked():
            active = []
            for job in self.ledger.all_jobs():
                transport_unblocked = False
                importer_unblocked = False
                indexer_unblocked = False
                if job["state"] in {
                    "needs_choice",
                    "succeeded",
                    "failed",
                    "needs_review",
                }:
                    continue
                if job.get("integration_required"):
                    transport_unblocked = (
                        job["state"] in {"searching", "downloading", "validating"}
                        and self.config.transport_isolated
                    )
                    importer_unblocked = (
                        job["state"] == "ready" and self.importer is not None
                    )
                    indexer_unblocked = (
                        job["state"] == "indexing" and self.indexer is not None
                    )
                    if (
                        not transport_unblocked
                        and not importer_unblocked
                        and not indexer_unblocked
                    ):
                        continue
                if (
                    _due(job.get("next_attempt_at"))
                    or transport_unblocked
                    or importer_unblocked
                    or indexer_unblocked
                ):
                    active.append(job)
            if not active:
                return None
            active.sort(
                key=lambda item: (
                    item.get("next_attempt_at", item["updated_at"]),
                    item["updated_at"],
                    item["job_id"],
                )
            )
            return active[0], active[0]["revision"]

    def _check_transfer_targets(self, intent: dict, *, expect_absent: bool) -> None:
        for item in intent["files"]:
            relative = item["expected_relative"]
            path = Path(self.config.download_root) / relative
            exists = path.exists() or path.is_symlink()
            if expect_absent and exists:
                raise InvalidInput("expected completed target already exists")
            if not expect_absent and not exists:
                raise InvalidInput("expected completed target is missing")

    def _transfer_files(self, job: dict, offer: dict) -> list[dict]:
        track_map = {
            (track["disc"], track["track"]): track
            for track in job["resolved_release"]["tracks"]
        }
        files = []
        total = 0
        for row in offer["files"]:
            key = (row["disc"], row["track"])
            if key not in track_map:
                raise InvalidInput("source mapping is inconsistent")
            reported_length = row.get("length")
            expected_duration = track_map[key]["duration_ms"]
            if isinstance(reported_length, (int, float)) and not isinstance(
                reported_length, bool
            ):
                reported_ms = reported_length * 1000
                if abs(reported_ms - expected_duration) > max(
                    10_000, expected_duration * 0.1
                ):
                    raise InvalidInput("source duration does not match resolved track")
            total += row["size"]
            relative = expected_batch_relative(job["job_id"], row["remote"])
            files.append(
                {
                    **row,
                    "recording_mbid": track_map[key]["recording_mbid"],
                    "duration_ms": track_map[key]["duration_ms"],
                    "expected_relative": str(relative),
                    "requested_at": None,
                }
            )
        if (
            not files
            or len(files) > self.config.max_files
            or total > self.config.max_bytes
        ):
            raise InvalidInput("source exceeds configured limits")
        basenames = [Path(item["expected_relative"]).name for item in files]
        if len(set(basenames)) != len(basenames):
            raise InvalidInput(
                "duplicate remote basenames collide in batch destination"
            )
        return files

    def _build_transfer_intent(self, job: dict, offer: dict, *, cleanup: str) -> None:
        files = self._transfer_files(job, offer)
        for item in files:
            path = Path(self.config.download_root) / item["expected_relative"]
            try:
                path.lstat()
            except FileNotFoundError:
                pass
            else:
                raise InvalidInput("expected completed target already exists")
        job["selected_source"] = {
            "peer": offer["peer"],
            "directory": offer["directory"],
        }
        job["selected_offer"] = offer
        job["selected_quality"] = offer["quality"]
        job["transfer_intent"] = {
            "status": "intent",
            "peer": offer["peer"],
            "files": files,
            "requested_at": now(),
            "source_digest": digest(files),
            "cleanup": cleanup,
            "batch_id": str(uuid.uuid4()),
            "payload_observed": False,
        }
        for item in job["transfer_intent"]["files"]:
            item["requested_at"] = job["transfer_intent"]["requested_at"]

    def _validated_offers(self, job: dict, offers: list[dict]) -> list[dict]:
        valid = []
        for offer in offers:
            try:
                self._transfer_files(job, offer)
            except (KeyError, InvalidInput):
                continue
            valid.append(offer)
        return valid

    def _validated_offer_pool(self, job: dict, offers: list[dict]) -> list[dict]:
        return offer_pool(self._validated_offers(job, offers), job["policy"])

    def _prepare_transfer(
        self, job: dict, offer: dict, *, cleanup: str = "pending"
    ) -> None:
        self._build_transfer_intent(job, offer, cleanup=cleanup)
        transition(job, "downloading")

    @staticmethod
    def _offer_plan(job: dict) -> dict | None:
        if "offer_plan" not in job:
            return None
        plan = job["offer_plan"]
        if (
            not isinstance(plan, dict)
            or not isinstance(plan.get("offers"), list)
            or not 1 <= len(plan["offers"]) <= MAX_PEER_ATTEMPTS
            or type(plan.get("cursor")) is not int
            or not 0 <= plan["cursor"] < len(plan["offers"])
            or not isinstance(plan.get("history"), list)
            or len(plan["history"]) > MAX_PEER_ATTEMPTS
            or len(plan["history"]) != plan["cursor"]
        ):
            raise InvalidInput("invalid durable offer plan")
        peers = set()
        for offer in plan["offers"]:
            if (
                not isinstance(offer, dict)
                or not isinstance(offer.get("peer"), str)
                or not offer["peer"].strip()
                or offer["peer"] in peers
            ):
                raise InvalidInput("invalid durable offer plan")
            peers.add(offer["peer"])
        active_peer = plan["offers"][plan["cursor"]]["peer"]
        for value in (job.get("selected_offer"), job.get("transfer_intent")):
            if value is not None and (
                not isinstance(value, dict) or value.get("peer") != active_peer
            ):
                raise InvalidInput("invalid durable offer plan")
        intent = job.get("transfer_intent")
        if intent is not None and type(intent.get("payload_observed")) is not bool:
            raise InvalidInput("invalid durable offer plan")
        source = job.get("selected_source")
        if source is not None and (
            not isinstance(source, dict) or source.get("peer") != active_peer
        ):
            raise InvalidInput("invalid durable offer plan")
        if any(
            not isinstance(item, dict)
            or not isinstance(item.get("peer"), str)
            or not item["peer"].strip()
            or not isinstance(item.get("batch_id"), str)
            or not item["batch_id"].strip()
            for item in plan["history"]
        ):
            raise InvalidInput("invalid durable offer plan")
        return plan

    def _check_empty_transfer_destination(self, job: dict) -> None:
        destination = Path(self.config.download_root) / "openclaw" / job["job_id"]
        try:
            destination.lstat()
        except FileNotFoundError:
            return
        if (
            destination.is_symlink()
            or not destination.is_dir()
            or any(destination.iterdir())
        ):
            raise InvalidInput("transfer destination contains unexpected entries")

    @staticmethod
    def _clean_rejection_evidence(intent: dict, records: list[dict]) -> bool:
        if intent.get("payload_observed") is not False:
            return False
        for record in records:
            flags = state_flags(record["state"])
            if (
                flags != {"completed", "rejected"}
                or type(record.get("bytes")) is not int
                or record["bytes"] != 0
                or record.get("attempts") != 1
                or not timestamp_after(
                    record["timestamps"].get("requestedAt"), intent["requested_at"]
                )
                or not timestamp_after(
                    record["timestamps"].get("endedAt"), intent["requested_at"]
                )
            ):
                return False
        return bool(records)

    def _reconcile_transfer(self, intent: dict) -> tuple[str, list[dict]]:
        records = self.slskd.transfers()
        expected = {
            (item["peer"], item["remote"], item["size"]): item
            for item in intent["files"]
        }
        matches = []
        for record in records:
            if (record["peer"], record["remote"], record["size"]) not in expected:
                continue
            if record.get("batch_id") != intent[
                "batch_id"
            ] and _zero_byte_rejected_transfer(record):
                continue
            matches.append(record)
        for record in matches:
            if record.get("batch_id") != intent["batch_id"]:
                return "needs_review", matches
        keys = [
            (record["peer"], record["remote"], record["size"]) for record in matches
        ]
        if len(set(keys)) != len(keys) or len(
            {record["id"] for record in matches}
        ) != len(matches):
            return "ambiguous", matches
        if not matches:
            return "not_started", []
        if set(keys) != set(expected):
            return "partial", matches
        if any(
            not timestamp_after(
                record["timestamps"].get("requestedAt")
                or record["timestamps"].get("enqueuedAt"),
                intent["requested_at"],
            )
            for record in matches
        ):
            return "stale", matches
        if any(
            type(record.get("bytes")) is int and record["bytes"] > 0
            for record in matches
        ):
            intent["payload_observed"] = True
        if any(
            transfer_failed(record["state"])
            or (
                "completed" in str(record["state"]).casefold()
                and not transfer_succeeded(record["state"])
            )
            for record in matches
        ):
            if all(
                transfer_failed(record["state"])
                and _zero_byte_rejected_transfer(record)
                for record in matches
            ):
                return "failed_zero_bytes", matches
            return "failed", matches
        if all(
            transfer_succeeded(record["state"]) and record["bytes"] == record["size"]
            for record in matches
        ):
            return "complete", matches
        return "pending", matches

    def _fail_zero_byte_transfer_rejection(
        self, job: dict, revision: int, records: list[dict]
    ) -> dict:
        plan = self._offer_plan(job)
        intent = job["transfer_intent"]
        if plan is not None:
            if not self._clean_rejection_evidence(intent, records):
                raise InvalidInput("transfer rejection evidence is not exact")
            if plan["cursor"] + 1 < len(plan["offers"]):
                self._check_empty_transfer_destination(job)
                plan["history"].append(
                    {
                        "cursor": plan["cursor"],
                        "peer": intent["peer"],
                        "batch_id": intent["batch_id"],
                        "started_at": intent["requested_at"],
                        "ended_at": max(
                            record["timestamps"]["endedAt"] for record in records
                        ),
                        "outcome": "rejected",
                        "transfer_ids": sorted(record["id"] for record in records)[:20],
                    }
                )
                plan["history"] = plan["history"][-MAX_PEER_ATTEMPTS:]
                plan["cursor"] += 1
                self._build_transfer_intent(
                    job, plan["offers"][plan["cursor"]], cleanup="done"
                )
                job["next_attempt_at"] = now()
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
        reasons = sorted(
            {
                record["exception"]
                for record in records
                if isinstance(record.get("exception"), str)
            }
        )
        message = "all transfers were rejected before any data was downloaded"
        if reasons:
            message += f" ({_bounded_text(reasons[0], 80)})"
        attempted = []
        if plan is not None:
            attempted = [
                f"{item['peer']} ({item['batch_id']})" for item in plan["history"]
            ] + [f"{intent['peer']} ({intent['batch_id']})"]
        action = "wait or change source, then submit a new request with a new idempotency key"
        attempt_text = f"; attempted {', '.join(attempted)[:120]}" if attempted else ""
        transition(
            job,
            "failed",
            error={
                "code": "transfer_rejected",
                "message": f"{message}{attempt_text}; {action}",
                "retryable": False,
                "resume_phase": None,
                "manual_action": action,
            },
        )
        self._commit(job, revision)
        return public(job, "worker")

    def _receipt_valid(self, receipt: object, identity: dict, count: int) -> bool:
        if not isinstance(receipt, dict) or any(
            receipt.get(key) != value for key, value in identity.items()
        ):
            return False
        if (
            not self.config.library_root
            or not isinstance(receipt.get("receipt_id"), str)
            or not receipt["receipt_id"].strip()
        ):
            return False
        if (
            not isinstance(receipt.get("album_id"), str)
            or not receipt["album_id"].strip()
            or receipt.get("success") is not True
        ):
            return False
        items = receipt.get("items")
        final_paths = receipt.get("final_paths")
        if (
            not isinstance(items, list)
            or not isinstance(final_paths, list)
            or len(items) != count
            or len(final_paths) != count
        ):
            return False
        root = Path(self.config.library_root).resolve()
        source_names = set()
        item_ids = set()
        paths = []
        for item in items:
            if (
                not isinstance(item, dict)
                or not isinstance(item.get("id"), str)
                or not item["id"].strip()
            ):
                return False
            if (
                not isinstance(item.get("source_name"), str)
                or not item["source_name"]
                or not isinstance(item.get("final_path"), str)
            ):
                return False
            path = Path(item["final_path"])
            if not path.is_absolute() or path.is_symlink():
                return False
            resolved = path.resolve()
            if root not in resolved.parents:
                return False
            source_names.add(item["source_name"])
            item_ids.add(item["id"])
            paths.append(str(resolved))
        manifest_names = {
            item["name"]
            for item in self.ledger.get(identity["job_id"])["manifest"] or []
        }
        return (
            len(source_names) == count
            and len(item_ids) == count
            and source_names == manifest_names
            and len(set(paths)) == count
            and paths == final_paths
        )

    def worker_once(self) -> dict:
        with self.ledger.worker_locked():
            selected = self._select_job()
            if selected is None:
                return {"schema": 1, "operation": "worker", "state": "idle"}
            job, revision = selected
            try:
                return self._work(job, revision)
            except Exception as error:  # noqa: BLE001 - durable worker error boundary
                return self._error(job, revision, error)

    def _work(self, job: dict, revision: int) -> dict:
        state = job["state"]
        if state == "queued":
            transition(job, "resolving")
            self._commit(job, revision)
            return public(job, "worker")
        if state == "resolving":
            result = self.resolver.resolve(
                job["request"], job.get("selections"), job["as_of"]
            )
            if result["state"] == "needs_choice":
                self._candidate_set(job, result["stage"], result["candidates"])
            else:
                job["resolved_release"] = result["resolved_release"]
                transition(job, "searching")
            self._commit(job, revision)
            return public(job, "worker")
        if state == "searching":
            search = job.get("search")
            if search is None:
                job["search"] = {
                    "status": "reconciling",
                    "id": str(uuid.uuid4()),
                    "text": job["resolved_release"]["search_text"],
                    "created_at": now(),
                    "post_started": False,
                }
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            if search["status"] == "reconciling":
                try:
                    self.slskd.search_status(search["id"])
                except BackendNotFound:
                    if search.get("post_started"):
                        raise BackendUncertain(
                            "search POST outcome is unknown and the intended search is absent"
                        )
                    search["status"] = "not_started"
                else:
                    search["status"] = "created"
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            if search["status"] == "not_started":
                search["status"] = "posting"
                search["post_started"] = True
                touch(job)
                self._commit(job, revision)
                try:
                    self.slskd.create_search(search["id"], search["text"])
                except BackendUncertain:
                    return public(job, "worker")
                job = self.ledger.get(job["job_id"])
                revision = job["revision"]
                job["search"]["status"] = "created"
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            if search["status"] == "posting":
                try:
                    self.slskd.search_status(search["id"])
                except BackendNotFound:
                    raise BackendUncertain(
                        "search POST outcome is unknown and the intended search is absent"
                    ) from None
                search["status"] = "created"
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            if search["status"] != "created":
                raise InvalidInput("invalid durable search state")
            if not self.slskd.search_complete(search["id"]):
                job["next_attempt_at"] = now()
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            rows = self.slskd.responses(search["id"])
            offer = job.get("selected_offer")
            if offer is None:
                offers = source_offers(rows, job["resolved_release"]["tracks"])
                pool = self._validated_offer_pool(job, offers)
                offer = pool[0] if pool else None
            else:
                pool = [offer]
            if offer is None:
                if job["policy"]["profile"] != "lossless-preferred":
                    raise InvalidInput(
                        "no complete source matches the release manifest"
                    )
                choices = [
                    item
                    for item in self._validated_offers(job, offers)
                    if item["complete"]
                ]
                if not choices:
                    raise InvalidInput(
                        "no complete source matches the release manifest"
                    )
                self._candidate_set(
                    job,
                    "source_quality",
                    [
                        {
                            "label": f"{item['peer']} ({item['quality']})",
                            "reason": "source or quality choice",
                            "offer": item,
                        }
                        for item in choices
                    ],
                )
                self._commit(job, revision)
                return public(job, "worker")
            if not self.config.transport_isolated:
                job["integration_required"] = (
                    "transport isolation assertion is required before transfer preparation"
                )
                job["next_attempt_at"] = "9999-12-31T23:59:59+00:00"
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            if job.get("integration_required"):
                job.pop("integration_required", None)
                job["next_attempt_at"] = now()
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            job["offer_plan"] = {
                "offers": pool[:MAX_PEER_ATTEMPTS],
                "cursor": 0,
                "history": [],
            }
            self._prepare_transfer(job, offer)
            self._commit(job, revision)
            return public(job, "worker")
        if state == "downloading":
            self._offer_plan(job)
            if job.get("integration_required"):
                if not self.config.transport_isolated:
                    return public(job, "worker")
                job.pop("integration_required", None)
                job["next_attempt_at"] = now()
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            intent = job["transfer_intent"]
            if intent["cleanup"] in {"pending", "retrying"}:
                try:
                    self.slskd.delete_search(job["search"]["id"])
                except BackendNotFound:
                    pass
                except BackendUncertain:
                    intent["cleanup"] = "retrying"
                    touch(job)
                    self._commit(job, revision)
                    return public(job, "worker")
                intent["cleanup"] = "done"
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            if intent["status"] == "intent":
                if not self.config.transport_isolated:
                    job["integration_required"] = (
                        "transport isolation assertion is required before queue POST"
                    )
                    job["next_attempt_at"] = "9999-12-31T23:59:59+00:00"
                    touch(job)
                    self._commit(job, revision)
                    return public(job, "worker")
                self._check_transfer_targets(intent, expect_absent=True)
                intent["status"] = "queue_calling"
                intent["queue_post_started"] = True
                touch(job)
                self._commit(job, revision)
                try:
                    self.slskd.queue(
                        intent["peer"],
                        intent["files"],
                        batch_id=intent["batch_id"],
                        job_id=job["job_id"],
                        search_id=job["search"]["id"],
                    )
                except BackendUncertain:
                    return public(job, "worker")
                except MusicError as error:
                    job = self.ledger.get(job["job_id"])
                    revision = job["revision"]
                    diagnostic = (
                        error.detail.get("batch_response", "")[:240]
                        if isinstance(error.detail, dict)
                        else ""
                    )
                    transition(
                        job,
                        "needs_review",
                        error={
                            "code": error.symbol,
                            "message": error.message[:240],
                            "diagnostic": diagnostic,
                            "retryable": False,
                            "resume_phase": None,
                            "manual_action": "inspect slskd batch status before resubmitting",
                        },
                    )
                    self._commit(job, revision)
                    return public(job, "worker")
                job = self.ledger.get(job["job_id"])
                revision = job["revision"]
                job["transfer_intent"]["status"] = "submitted"
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            if intent["status"] == "queue_calling":
                if not self.config.transport_isolated:
                    job["integration_required"] = (
                        "transport isolation assertion is required before queue reconciliation"
                    )
                    job["next_attempt_at"] = "9999-12-31T23:59:59+00:00"
                    touch(job)
                    self._commit(job, revision)
                    return public(job, "worker")
                outcome, records = self._reconcile_transfer(intent)
                if outcome == "not_started":
                    raise BackendUncertain(
                        "queue POST was started but has no exact transfer evidence"
                    )
                if outcome == "failed_zero_bytes":
                    return self._fail_zero_byte_transfer_rejection(
                        job, revision, records
                    )
                if outcome not in {"pending", "complete"}:
                    raise InvalidInput("queue reconciliation is not exact")
                intent["status"] = "submitted"
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            if intent["status"] == "submitted":
                if not self.config.transport_isolated:
                    job["integration_required"] = (
                        "transport isolation assertion is required before transfer reconciliation"
                    )
                    job["next_attempt_at"] = "9999-12-31T23:59:59+00:00"
                    touch(job)
                    self._commit(job, revision)
                    return public(job, "worker")
                outcome, records = self._reconcile_transfer(intent)
                if outcome == "pending":
                    job["next_attempt_at"] = now()
                    touch(job)
                    self._commit(job, revision)
                    return public(job, "worker")
                if outcome == "failed_zero_bytes":
                    return self._fail_zero_byte_transfer_rejection(
                        job, revision, records
                    )
                if outcome != "complete":
                    raise InvalidInput("transfer reconciliation failed: " + outcome)
                intent["evidence"] = records
                transition(job, "validating")
                self._commit(job, revision)
                return public(job, "worker")
            raise InvalidInput("invalid durable queue state")
        if state == "validating":
            if not self.config.transport_isolated:
                raise InvalidInput(
                    "Phase 2 transport isolation assertion is required before capture"
                )
            intent = job["transfer_intent"]
            self._check_transfer_targets(intent, expect_absent=False)
            evidence = {
                (record["peer"], record["remote"], record["size"]): record
                for record in intent.get("evidence", [])
            }
            files = []
            for expected in intent["files"]:
                key = (expected["peer"], expected["remote"], expected["size"])
                record = evidence.get(key)
                if record is None or not transfer_succeeded(record["state"]):
                    raise InvalidInput("missing successful transfer provenance")
                files.append(expected)
            if not job.get("capture_intent"):
                job["capture_intent"] = {"created_at": now(), "status": "copying"}
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            directory, manifest, measurements = capture(
                self.config.download_root,
                self.config.staging_root,
                job["job_id"],
                files,
                max_bytes=self.config.max_bytes,
                validator=self.validator,
                policy=job["policy"],
            )
            for item, measurement in zip(manifest, measurements, strict=True):
                expected_duration = item["duration_ms"]
                measured_duration = measurement["duration"] * 1000
                tolerance = max(10_000, expected_duration * 0.1)
                if abs(measured_duration - expected_duration) > tolerance:
                    raise InvalidInput(
                        "captured duration does not match resolved track"
                    )
            job["manifest"] = manifest
            job["stage_path"] = str(directory)
            transition(job, "ready")
            self._commit(job, revision)
            return public(job, "worker")
        if state == "ready":
            if self.importer is None:
                job["integration_required"] = (
                    "beets structured receipt adapter is required"
                )
                job["next_attempt_at"] = "9999-12-31T23:59:59+00:00"
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            if job.get("integration_required"):
                job.pop("integration_required", None)
                job["next_attempt_at"] = now()
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            identity = {
                "job_id": job["job_id"],
                "release_mbid": job["resolved_release"]["mbid"],
                "manifest_digest": digest(job["manifest"]),
                "behavior": self.importer.behavior_identity,
                "expected_tracks": [
                    {"name": item["name"], "disc": item["disc"], "track": item["track"]}
                    for item in job["manifest"]
                ],
                "policy": job["policy"],
                "selected_quality": job["selected_quality"],
            }
            outcome, receipt = self.importer.reconcile_import(identity)
            if outcome == "complete":
                if not self._receipt_valid(receipt, identity, len(job["manifest"])):
                    raise InvalidInput("import receipt is incomplete or mismatched")
                job["import_receipt"] = receipt
                job["final_library_path"] = receipt["final_paths"]
                transition(job, "indexing")
            elif outcome == "not_started":
                job["import_intent"] = {"identity": identity, "status": "intent"}
                transition(job, "importing")
            else:
                raise InvalidInput("import reconciliation is " + str(outcome))
            self._commit(job, revision)
            return public(job, "worker")
        if state == "importing":
            intent = job["import_intent"]
            identity = intent["identity"]
            if intent["status"] == "calling":
                # Correlation rows may exist before stock beets finishes file work.
                raise BackendUncertain(
                    "stock beets invocation acknowledgement is missing; inspect beets log/library and do not retry this job"
                )
            outcome, receipt = self.importer.reconcile_import(identity)
            if outcome == "complete":
                if not self._receipt_valid(receipt, identity, len(job["manifest"])):
                    raise InvalidInput("import receipt is incomplete or mismatched")
                job["import_receipt"] = receipt
                job["final_library_path"] = receipt["final_paths"]
                transition(job, "indexing")
                self._commit(job, revision)
                return public(job, "worker")
            if intent["status"] == "cli_succeeded" and outcome != "complete":
                raise InvalidInput(
                    "acknowledged beets invocation lacks verified receipt"
                )
            if outcome != "not_started":
                raise InvalidInput("import outcome cannot be safely resumed")
            if intent["status"] != "intent":
                raise InvalidInput("invalid import intent state")
            intent["status"] = "calling"
            touch(job)
            self._commit(job, revision)
            receipt = self.importer.import_album(
                {"stage": job["stage_path"], "manifest": job["manifest"]}, identity
            )
            if not self._receipt_valid(receipt, identity, len(job["manifest"])):
                raise InvalidInput("import receipt is incomplete or mismatched")
            job = self.ledger.get(job["job_id"])
            revision = job["revision"]
            job["import_intent"]["status"] = "cli_succeeded"
            job["import_receipt"] = receipt
            job["final_library_path"] = receipt["final_paths"]
            transition(job, "indexing")
            touch(job)
            self._commit(job, revision)
            return public(job, "worker")
        if state == "indexing":
            if self.indexer is None:
                if (
                    job.get("import_receipt", {}).get("behavior")
                    == "openclaw-beets-cli-v1"
                ):
                    job["mpd_result"] = {
                        "success": True,
                        "mechanism": "beets-mpdupdate",
                        "verified": False,
                    }
                    transition(job, "succeeded")
                    self._commit(job, revision)
                    return public(job, "worker")
                job["integration_required"] = "MPD index adapter is required"
                job["next_attempt_at"] = "9999-12-31T23:59:59+00:00"
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            if job.get("integration_required"):
                job.pop("integration_required", None)
                job["next_attempt_at"] = now()
                touch(job)
                self._commit(job, revision)
                return public(job, "worker")
            try:
                result = self.indexer.index(job["import_receipt"])
            except Exception:  # noqa: BLE001 - external index adapter boundary
                result = None
            if not isinstance(result, dict) or result.get("success") is not True:
                transition(
                    job,
                    "failed",
                    retryable=True,
                    resume_phase="indexing",
                    error={
                        "code": "index_failed",
                        "message": "index adapter did not report explicit success",
                    },
                )
                self._commit(job, revision)
                return public(job, "worker")
            job["mpd_result"] = result
            transition(job, "succeeded")
            self._commit(job, revision)
            return public(job, "worker")
        raise Conflict("worker cannot run this state")

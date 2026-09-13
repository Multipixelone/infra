from __future__ import annotations

import hashlib
import json
import uuid
from datetime import UTC, datetime

from .errors import Conflict, InvalidInput

TERMINAL = {"succeeded", "needs_review"}
STATES = {
    "queued",
    "resolving",
    "needs_choice",
    "searching",
    "downloading",
    "validating",
    "ready",
    "importing",
    "indexing",
    "succeeded",
    "failed",
    "needs_review",
}
TRANSITIONS = {
    "queued": {"resolving", "failed", "needs_review"},
    "resolving": {"needs_choice", "searching", "failed", "needs_review"},
    "needs_choice": {"resolving", "searching", "failed", "needs_review"},
    "searching": {"needs_choice", "downloading", "failed", "needs_review"},
    "downloading": {"validating", "failed", "needs_review"},
    "validating": {"ready", "failed", "needs_review"},
    "ready": {"importing", "indexing", "needs_review"},
    "importing": {"indexing", "failed", "needs_review"},
    "indexing": {"succeeded", "failed", "needs_review"},
    "failed": {
        "resolving",
        "searching",
        "downloading",
        "validating",
        "ready",
        "indexing",
    },
    "succeeded": set(),
    "needs_review": set(),
}


def now() -> str:
    return datetime.now(UTC).isoformat()


def digest(value: object) -> str:
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    )
    return hashlib.sha256(encoded.encode("ascii")).hexdigest()


def touch(job: dict) -> None:
    job["revision"] += 1
    job["updated_at"] = now()


def transition(
    job: dict,
    target: str,
    *,
    retryable: bool = False,
    resume_phase: str | None = None,
    error: dict | None = None,
) -> None:
    if target not in STATES or target not in TRANSITIONS.get(job["state"], set()):
        raise Conflict("invalid state transition")
    job["state"] = target
    job["retryable"] = retryable
    job["resume_phase"] = resume_phase
    job["error"] = error
    touch(job)


def parse_uuid(value: object) -> str:
    if not isinstance(value, str):
        raise InvalidInput("job_id must be a UUID")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        raise InvalidInput("job_id must be a UUID") from None
    if str(parsed) != value:
        raise InvalidInput("job_id must be a canonical UUID")
    return value


def new_job(raw_request: dict, effective_policy: dict) -> dict:
    stamp = now()
    return {
        "schema": 1,
        "job_id": str(uuid.uuid4()),
        "revision": 1,
        "state": "queued",
        "raw_request": raw_request,
        "request": {k: v for k, v in raw_request.items() if k != "idempotency_key"},
        "request_digest": digest(
            {k: v for k, v in raw_request.items() if k != "idempotency_key"}
        ),
        "policy": effective_policy,
        "policy_digest": digest(effective_policy),
        "candidate_sets": {},
        "decisions": {},
        "selections": {},
        "current_set": None,
        "search": None,
        "transfer_intent": None,
        "manifest": None,
        "import_intent": None,
        "import_receipt": None,
        "mpd_result": None,
        "error": None,
        "retryable": False,
        "resume_phase": None,
        "next_attempt_at": stamp,
        "created_at": stamp,
        "updated_at": stamp,
    }

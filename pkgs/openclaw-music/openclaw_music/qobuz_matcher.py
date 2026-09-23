"""Deterministic, report-only evidence for Spotify album to Qobuz searches.

This module deliberately works with Streamrip's sparse ``{id, desc}`` search
records.  A description is evidence, not provider metadata: fields which are
not present in the description remain absent from the score.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unicodedata
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
POLICY_VERSION = 1
MAX_QUERY_STAGES = 4
MAX_CANDIDATES = 200

_SPACE = re.compile(r"\s+")
_PUNCTUATION = re.compile(r"[\W_]+", re.UNICODE)
_EDITION_PATTERNS = {
    "live": re.compile(r"\blive\b", re.IGNORECASE),
    "studio": re.compile(r"\bstudio\b", re.IGNORECASE),
    "karaoke": re.compile(r"\bkaraoke\b", re.IGNORECASE),
    "tribute": re.compile(r"\btribute\b", re.IGNORECASE),
    "cover": re.compile(r"\bcovers?\b", re.IGNORECASE),
    "cast": re.compile(r"\b(?:original\s+)?cast\b", re.IGNORECASE),
    "remix": re.compile(r"\bremix(?:ed)?\b", re.IGNORECASE),
    "remaster": re.compile(r"\bremaster(?:ed)?\b", re.IGNORECASE),
    "clean": re.compile(r"\bclean\b", re.IGNORECASE),
    "explicit": re.compile(r"\bexplicit\b", re.IGNORECASE),
}
_RETRIEVAL_QUALIFIER = re.compile(
    r"\s*(?:\(|\[|\{)\s*(?:standard\s+version|special\s+edition|deluxe(?:\s+edition)?|(?:\d+(?:st|nd|rd|th)\s+)?anniversary(?:\s+edition)?|expanded|live|remaster(?:ed)?|remix(?:ed)?|clean|explicit|karaoke|tribute|cover(?:s)?|original\s+cast|cast)\s*[\)\]\}]\s*$",
    re.IGNORECASE,
)
_OUTCOMES = {"results", "empty", "command_failure", "timeout", "malformed_response"}
_STATUSES = {
    "beets_owned",
    "cached_match_reused",
    "cached_skip_reused",
    "selection_search_failed",
    "selection_no_results",
    "selection_malformed_response",
    "selection_ambiguous_noninteractive",
    "selection_cancelled",
    "selection_skipped",
    "selection_auto",
    "selection_manual",
}


class EvidenceError(ValueError):
    """Input or output did not meet the versioned evidence contract."""


def normalize(value: str) -> str:
    """Normalize one field without joining its token boundaries."""
    if not isinstance(value, str):
        raise EvidenceError("fields must be strings")
    decomposed = unicodedata.normalize("NFKD", value)
    without_marks = "".join(c for c in decomposed if not unicodedata.combining(c))
    tokenized = _PUNCTUATION.sub(" ", without_marks.casefold())
    return _SPACE.sub(" ", tokenized).strip()


def edition_signals(value: str) -> list[str]:
    return [
        name for name, pattern in _EDITION_PATTERNS.items() if pattern.search(value)
    ]


def strip_retrieval_qualifiers(title: str) -> str:
    """Remove only trailing, recognised bracketed editions for retrieval."""
    if not isinstance(title, str):
        raise EvidenceError("title must be a string")
    stripped = _RETRIEVAL_QUALIFIER.sub("", title).strip()
    return stripped or title.strip()


def plan_queries(title: str, artist: str) -> list[dict[str, str]]:
    """Return ordered bounded retrieval queries; never inject a literal 'by'."""
    if (
        not isinstance(title, str)
        or not title.strip()
        or not isinstance(artist, str)
        or not artist.strip()
    ):
        raise EvidenceError("title and artist must be non-empty strings")
    raw_title, raw_artist = title.strip(), artist.strip()
    retrieval_title = strip_retrieval_qualifiers(raw_title)
    proposals = [
        ("title_artist", f"{raw_title} {raw_artist}"),
        ("edition_stripped_title_artist", f"{retrieval_title} {raw_artist}"),
        ("title_only", raw_title),
    ]
    seen: set[str] = set()
    queries = []
    for stage, query in proposals:
        key = normalize(query)
        if key and key not in seen:
            seen.add(key)
            queries.append({"stage": stage, "query": query})
    return queries[:MAX_QUERY_STAGES]


def classify_streamrip_search(
    returncode: int, timed_out: bool, output: str | None
) -> str:
    """Classify the pinned Streamrip search-file boundary for regression tests.

    ``None`` means the pre-call-removed output file was not recreated.  An
    existing file, including an empty one, must parse as the exact sparse
    Streamrip array shape before it can be treated as a successful result.
    """
    if timed_out:
        return "timeout"
    if type(returncode) is not int:
        raise EvidenceError("search return code must be an integer")
    if returncode != 0:
        return "command_failure"
    if output is None:
        return "empty"
    try:
        value = json.loads(output)
    except (TypeError, json.JSONDecodeError):
        return "malformed_response"
    if not isinstance(value, list) or len(value) > 50:
        return "malformed_response"
    for candidate in value:
        if (
            not isinstance(candidate, dict)
            or set(candidate) != {"id", "desc", "source", "media_type"}
            or candidate["source"] != "qobuz"
            or candidate["media_type"] != "album"
            or not isinstance(candidate["id"], str)
            or not candidate["id"]
            or not isinstance(candidate["desc"], str)
            or not candidate["desc"]
        ):
            return "malformed_response"
    return "empty" if not value else "results"


def parse_sparse_candidate(record: Mapping[str, Any]) -> dict[str, Any]:
    """Parse only title/artist that a Streamrip display string actually states."""
    if not isinstance(record, Mapping) or set(record) != {"id", "desc"}:
        raise EvidenceError("candidate must contain exactly id and desc")
    candidate_id, desc = record["id"], record["desc"]
    if (
        not isinstance(candidate_id, str)
        or not candidate_id
        or not isinstance(desc, str)
        or not desc
    ):
        raise EvidenceError("candidate id and desc must be non-empty strings")
    # Streamrip normally displays ``Album by Artist``.  Multiple delimiters
    # cannot safely distinguish an album title from an artist name.  Retain a
    # final-delimiter interpretation for exploratory ranking, but label it so
    # it can never authorize a recommendation.
    fields: dict[str, str] = {}
    delimiters = list(re.finditer(r"\s+by\s+", desc, flags=re.IGNORECASE))
    if delimiters:
        delimiter = delimiters[-1]
        title, artist = (
            desc[: delimiter.start()].strip(),
            desc[delimiter.end() :].strip(),
        )
        if title and artist:
            fields = {"title": title, "artist": artist}
    return {
        "id": candidate_id,
        "desc": desc,
        "fields": fields,
        "ambiguous": len(delimiters) > 1,
    }


def _similarity(expected: str, observed: str, exact: int, partial: int) -> int:
    if not expected or not observed:
        return 0
    if expected == observed:
        return exact
    expected_tokens, observed_tokens = set(expected.split()), set(observed.split())
    if not expected_tokens or not observed_tokens:
        return 0
    overlap = len(expected_tokens & observed_tokens)
    union = len(expected_tokens | observed_tokens)
    return round(partial * overlap / union) if overlap else 0


def _vetoes(source_title: str, candidate_title: str) -> list[str]:
    source, candidate = (
        set(edition_signals(source_title)),
        set(edition_signals(candidate_title)),
    )
    vetoes: list[str] = []
    for left, right, name in (
        ("live", "studio", "live_studio_conflict"),
        ("studio", "live", "live_studio_conflict"),
        ("clean", "explicit", "clean_explicit_conflict"),
        ("explicit", "clean", "clean_explicit_conflict"),
    ):
        if left in source and right in candidate:
            vetoes.append(name)
    # These labels identify an alternate performance/edition if present on
    # only one side.  Do not infer their absence from sparse descriptions.
    for signal in ("karaoke", "tribute", "cover", "cast", "remix", "remaster"):
        if (signal in source) != (signal in candidate):
            vetoes.append(f"{signal}_conflict")
    return sorted(set(vetoes))


def score_candidate(
    source: Mapping[str, Any], sparse: Mapping[str, Any]
) -> dict[str, Any]:
    """Score fixed evidence components; missing fields contribute zero."""
    source_title, source_artist = source["album"], source["artist"]
    fields = sparse["fields"]
    candidate_title = fields.get("title", "")
    candidate_artist = fields.get("artist", "")
    title_score = _similarity(
        normalize(source_title), normalize(candidate_title), 60, 45
    )
    artist_score = _similarity(
        normalize(source_artist), normalize(candidate_artist), 30, 20
    )
    source_signals, candidate_signals = (
        edition_signals(source_title),
        edition_signals(candidate_title),
    )
    edition_score = 10 if source_signals and source_signals == candidate_signals else 0
    vetoes = _vetoes(source_title, candidate_title) if candidate_title else []
    evidence_state = (
        "sufficient_sparse"
        if candidate_title and candidate_artist
        else "insufficient_evidence"
    )
    total = title_score + artist_score + edition_score
    return {
        "id": sparse["id"],
        "desc": sparse["desc"],
        "parsed": {
            "fields": fields,
            "source": "streamrip_desc",
            "ambiguous": sparse["ambiguous"],
        },
        "score": {
            "title": title_score,
            "artist": artist_score,
            "edition": edition_score,
            "total": total,
            "evidence_state": evidence_state,
        },
        "vetoes": vetoes,
    }


def rank_candidates(
    source: Mapping[str, Any], candidates: Iterable[Mapping[str, Any]]
) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    scored = [
        score_candidate(source, parse_sparse_candidate(candidate))
        for candidate in candidates
    ]
    ranked = sorted(
        scored,
        key=lambda item: (bool(item["vetoes"]), -item["score"]["total"], item["id"]),
    )
    eligible = [item for item in ranked if not item["vetoes"]]
    recommendation: dict[str, Any] | None = None
    if eligible:
        first = eligible[0]
        runner_up = eligible[1]["score"]["total"] if len(eligible) > 1 else 0
        margin = first["score"]["total"] - runner_up
        fields = first["parsed"]["fields"]
        exact_title = normalize(source["album"]) == normalize(fields.get("title", ""))
        exact_artist = normalize(source["artist"]) == normalize(
            fields.get("artist", "")
        )
        if (
            first["score"]["evidence_state"] == "sufficient_sparse"
            and not first["parsed"]["ambiguous"]
            and exact_title
            and exact_artist
            and first["score"]["total"] >= 90
            and margin >= 15
        ):
            recommendation = {
                "qobuz_id": first["id"],
                "score": first["score"]["total"],
                "margin": margin,
                "kind": "conservative_sparse",
            }
    return ranked, recommendation


def _source(value: Mapping[str, Any]) -> dict[str, str]:
    if not isinstance(value, Mapping) or set(value) != {
        "spotify_id",
        "artist",
        "album",
        "spotify_url",
    }:
        raise EvidenceError(
            "source must contain exactly spotify_id, artist, album, spotify_url"
        )
    if not all(isinstance(value[key], str) and value[key] for key in value):
        raise EvidenceError("source identity values must be non-empty strings")
    return dict(value)


def build_record(request: Mapping[str, Any]) -> dict[str, Any]:
    if (
        not isinstance(request, Mapping)
        or set(request)
        != {
            "schema",
            "source",
            "status",
            "query_stages",
            "candidates",
            "budget_truncated",
            "global_budget_incomplete",
        }
        or type(request["schema"]) is not int
        or request["schema"] != SCHEMA_VERSION
    ):
        raise EvidenceError("invalid matcher record request")
    source = _source(request["source"])
    status = request["status"]
    if (
        status not in _STATUSES
        or not isinstance(request["query_stages"], list)
        or not isinstance(request["candidates"], list)
        or not isinstance(request["budget_truncated"], bool)
        or not isinstance(request["global_budget_incomplete"], bool)
    ):
        raise EvidenceError("invalid matcher record fields")
    if (
        len(request["query_stages"]) > MAX_QUERY_STAGES
        or len(request["candidates"]) > MAX_CANDIDATES
    ):
        raise EvidenceError("matcher evidence budget exceeded")
    stages = []
    for stage in request["query_stages"]:
        if not isinstance(stage, Mapping) or set(stage) != {
            "stage",
            "query",
            "outcome",
            "result_count",
            "unique_candidate_count",
        }:
            raise EvidenceError("invalid query stage")
        if (
            not isinstance(stage["stage"], str)
            or not isinstance(stage["query"], str)
            or stage["outcome"] not in _OUTCOMES
            or not all(
                type(stage[key]) is int and stage[key] >= 0
                for key in ("result_count", "unique_candidate_count")
            )
        ):
            raise EvidenceError("invalid query stage values")
        stages.append(dict(stage))
    candidates = list(request["candidates"])
    ids = [
        candidate.get("id") if isinstance(candidate, Mapping) else None
        for candidate in candidates
    ]
    if len(ids) != len(set(ids)):
        raise EvidenceError("candidate ids must be unique")
    ranked, recommendation = rank_candidates(source, candidates)
    withheld_reasons: set[str] = set()
    if request["budget_truncated"]:
        withheld_reasons.add("retrieval_truncated")
    if request["global_budget_incomplete"]:
        withheld_reasons.add("global_budget_incomplete")
    for stage in stages:
        if stage["outcome"] == "command_failure":
            withheld_reasons.add("query_command_failure")
        elif stage["outcome"] == "timeout":
            withheld_reasons.add("query_timeout")
        elif stage["outcome"] == "malformed_response":
            withheld_reasons.add("query_malformed_response")
    for candidate in ranked:
        fields = candidate["parsed"]["fields"]
        if candidate["parsed"]["ambiguous"]:
            withheld_reasons.add("ambiguous_display_parsing")
        if not fields:
            withheld_reasons.add("missing_sparse_evidence")
    if not ranked:
        withheld_reasons.add("missing_sparse_evidence")
    if recommendation is not None and withheld_reasons:
        recommendation = None
    if recommendation is None and ranked and not withheld_reasons:
        first = next(
            (candidate for candidate in ranked if not candidate["vetoes"]), None
        )
        if first is not None:
            fields = first["parsed"]["fields"]
            if not fields:
                withheld_reasons.add("missing_sparse_evidence")
            elif normalize(source["album"]) != normalize(fields.get("title", "")):
                withheld_reasons.add("title_not_exact")
            elif normalize(source["artist"]) != normalize(fields.get("artist", "")):
                withheld_reasons.add("artist_not_exact")
            elif first["parsed"]["ambiguous"]:
                withheld_reasons.add("ambiguous_display_parsing")
            elif first["score"]["total"] < 90:
                withheld_reasons.add("below_confidence_threshold")
            else:
                withheld_reasons.add("insufficient_margin")
    return {
        "schema_version": SCHEMA_VERSION,
        "policy_version": POLICY_VERSION,
        "source": source,
        "status": status,
        "query_stages": stages,
        "candidate_count": len(ranked),
        "budget_truncated": request["budget_truncated"],
        "global_budget_incomplete": request["global_budget_incomplete"],
        "candidates": ranked,
        "recommended_candidate": recommendation,
        "recommendation_withheld_reasons": sorted(withheld_reasons),
    }


def build_manifest(records: Iterable[Mapping[str, Any]]) -> dict[str, Any]:
    checked = list(records)
    for record in checked:
        validate_record(record)
    spotify_ids = [record["source"]["spotify_id"] for record in checked]
    if len(spotify_ids) != len(set(spotify_ids)):
        raise EvidenceError("duplicate source spotify ids")
    return {
        "schema_version": SCHEMA_VERSION,
        "policy_version": POLICY_VERSION,
        "records": sorted(
            checked,
            key=lambda record: (
                normalize(record["source"]["artist"]),
                normalize(record["source"]["album"]),
                record["source"]["spotify_id"],
            ),
        ),
    }


def validate_manifest(manifest: Mapping[str, Any]) -> None:
    expected = {"schema_version", "policy_version", "records"}
    if (
        not isinstance(manifest, Mapping)
        or set(manifest) != expected
        or type(manifest["schema_version"]) is not int
        or type(manifest["policy_version"]) is not int
        or manifest["schema_version"] != SCHEMA_VERSION
        or manifest["policy_version"] != POLICY_VERSION
        or not isinstance(manifest["records"], list)
    ):
        raise EvidenceError("invalid evidence manifest schema")
    rebuilt = build_manifest(manifest["records"])
    if manifest != rebuilt:
        raise EvidenceError("non-canonical evidence manifest")


def validate_record(record: Mapping[str, Any]) -> None:
    expected = {
        "schema_version",
        "policy_version",
        "source",
        "status",
        "query_stages",
        "candidate_count",
        "budget_truncated",
        "global_budget_incomplete",
        "candidates",
        "recommended_candidate",
        "recommendation_withheld_reasons",
    }
    if (
        not isinstance(record, Mapping)
        or set(record) != expected
        or type(record["schema_version"]) is not int
        or type(record["policy_version"]) is not int
        or record["schema_version"] != SCHEMA_VERSION
        or record["policy_version"] != POLICY_VERSION
    ):
        raise EvidenceError("invalid evidence record schema")
    # Rebuild the record from its stable public inputs, then compare exactly.
    rebuilt = build_record(
        {
            "schema": SCHEMA_VERSION,
            "source": record["source"],
            "status": record["status"],
            "query_stages": record["query_stages"],
            "candidates": [
                {"id": item["id"], "desc": item["desc"]}
                for item in record["candidates"]
            ],
            "budget_truncated": record["budget_truncated"],
            "global_budget_incomplete": record["global_budget_incomplete"],
        }
    )
    if record != rebuilt:
        raise EvidenceError("non-canonical evidence record")


def serialize(value: Mapping[str, Any]) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _read_stdin() -> Any:
    try:
        return json.load(sys.stdin)
    except (json.JSONDecodeError, OSError) as exc:
        raise EvidenceError("invalid JSON input") from exc


def validate_evidence_destination(destination: str, artifacts: Iterable[str]) -> None:
    """Reject an evidence report path which aliases a legacy mutable artifact."""
    target = Path(destination)
    if target.exists() and target.is_dir():
        raise EvidenceError("evidence destination is a directory")
    try:
        canonical_target = target.resolve(strict=False)
    except OSError as exc:
        raise EvidenceError("could not normalize evidence destination") from exc
    for artifact in artifacts:
        other = Path(artifact)
        try:
            canonical_other = other.resolve(strict=False)
        except OSError as exc:
            raise EvidenceError("could not normalize legacy artifact") from exc
        if canonical_target == canonical_other:
            raise EvidenceError("evidence destination aliases a legacy artifact")
        if target.exists() and other.exists():
            try:
                if os.path.samefile(target, other):
                    raise EvidenceError(
                        "evidence destination aliases a legacy artifact"
                    )
            except OSError:
                # Equality of normalized paths above remains a conservative
                # check when samefile cannot inspect an inaccessible path.
                pass


def _run_reporter(reporter: str, operation: str, payload: Any) -> Any:
    """Run the versioned reporter boundary and decode its one JSON response."""
    try:
        result = subprocess.run(
            [reporter, operation],
            input=serialize(payload),
            text=True,
            capture_output=True,
            check=False,
        )
    except OSError as exc:
        raise EvidenceError(
            f"could not start evidence reporter ({type(exc).__name__})"
        ) from exc
    if result.returncode:
        raise EvidenceError(f"evidence reporter {operation} failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise EvidenceError(
            f"evidence reporter {operation} returned invalid JSON"
        ) from exc


def _requests(path: str) -> list[dict[str, Any]]:
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise EvidenceError(
            f"could not read evidence requests ({type(exc).__name__})"
        ) from exc
    requests = []
    for line in lines:
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as exc:
            raise EvidenceError("evidence requests contain invalid JSON") from exc
        if not isinstance(request, Mapping) or set(request) != {"source", "status"}:
            raise EvidenceError("evidence request has an invalid schema")
        source = _source(request["source"])
        if request["status"] not in _STATUSES:
            raise EvidenceError("evidence request has an invalid status")
        requests.append({"source": source, "status": request["status"]})
    return requests


def _query_plan(reporter: str, source: Mapping[str, Any]) -> list[dict[str, str]]:
    plan = _run_reporter(reporter, "queries", source)
    if (
        not isinstance(plan, Mapping)
        or set(plan) != {"schema_version", "policy_version", "queries"}
        or plan["schema_version"] != SCHEMA_VERSION
        or plan["policy_version"] != POLICY_VERSION
        or not isinstance(plan["queries"], list)
        or len(plan["queries"]) > MAX_QUERY_STAGES
    ):
        raise EvidenceError("evidence reporter returned an invalid query plan")
    queries = []
    for query in plan["queries"]:
        if (
            not isinstance(query, Mapping)
            or set(query) != {"stage", "query"}
            or not all(isinstance(query[key], str) and query[key] for key in query)
        ):
            raise EvidenceError("evidence reporter returned an invalid query plan")
        queries.append(dict(query))
    return queries


def _search(
    provider: str, query: str, output: Path, timeout: float
) -> tuple[str, list[dict[str, str]]]:
    try:
        result = subprocess.run(
            [
                provider,
                "search",
                "--output-file",
                str(output),
                "--num-results",
                "50",
                "qobuz",
                "album",
                query,
            ],
            stdout=subprocess.DEVNULL,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return "timeout", []
    except OSError as exc:
        raise EvidenceError(
            f"could not start evidence provider ({type(exc).__name__})"
        ) from exc
    if result.returncode:
        return ("timeout" if result.returncode == 124 else "command_failure"), []
    if not output.is_file():
        return "empty", []
    try:
        raw = output.read_text(encoding="utf-8")
    except OSError as exc:
        raise EvidenceError(
            f"could not read evidence provider output ({type(exc).__name__})"
        ) from exc
    outcome = classify_streamrip_search(0, False, raw)
    if outcome != "results":
        return outcome, []
    parsed = json.loads(raw)
    return "results", [{"id": item["id"], "desc": item["desc"]} for item in parsed]


def _publish(destination: Path, content: str, publisher: str | None) -> None:
    if destination.exists() and destination.is_dir():
        raise EvidenceError("evidence destination is a directory")
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=destination.parent,
            prefix=f".{destination.name}.",
            delete=False,
        ) as output:
            temporary = Path(output.name)
            os.chmod(temporary, 0o600)
            output.write(content)
        if publisher is None:
            os.replace(temporary, destination)
        else:
            result = subprocess.run(
                [publisher, str(temporary), str(destination)], check=False
            )
            if result.returncode:
                raise EvidenceError("evidence publisher failed")
            if temporary.exists():
                raise EvidenceError("evidence publisher did not replace the report")
    except OSError as exc:
        raise EvidenceError(
            f"could not publish evidence report ({type(exc).__name__})"
        ) from exc
    finally:
        if "temporary" in locals():
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass


def run_reporting_path(
    request_path: str,
    destination: str,
    provider: str,
    reporter: str,
    publisher: str | None = None,
    budget_seconds: float = 25,
) -> None:
    """Retrieve optional evidence and atomically replace its report on success.

    This is intentionally independent of legacy selection state.  Callers pass
    it only after legacy work and retain their own exit status on any failure.
    """
    if budget_seconds <= 0:
        raise EvidenceError("evidence budget must be positive")
    requests = _requests(request_path)
    records = []
    deadline = time.monotonic() + budget_seconds
    with tempfile.TemporaryDirectory(prefix="spotify-qobuz-evidence-") as directory:
        workdir = Path(directory)
        for index, request in enumerate(requests):
            stages: list[dict[str, Any]] = []
            candidates: dict[str, dict[str, str]] = {}
            budget_truncated = False
            global_budget_incomplete = False
            if request["status"].startswith("selection_"):
                for query in _query_plan(reporter, request["source"]):
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        global_budget_incomplete = True
                        break
                    if len(candidates) >= MAX_CANDIDATES:
                        budget_truncated = True
                        break
                    output = workdir / f"search-{index}-{query['stage']}.json"
                    outcome, found = _search(
                        provider, query["query"], output, min(8, remaining)
                    )
                    for candidate in found:
                        candidates.setdefault(candidate["id"], candidate)
                    if len(found) == 50:
                        budget_truncated = True
                    stages.append(
                        {
                            "stage": query["stage"],
                            "query": query["query"],
                            "outcome": outcome,
                            "result_count": len(found),
                            "unique_candidate_count": len(
                                {candidate["id"] for candidate in found}
                            ),
                        }
                    )
            record_request = {
                "schema": SCHEMA_VERSION,
                "source": request["source"],
                "status": request["status"],
                "query_stages": stages,
                "candidates": [candidates[key] for key in sorted(candidates)],
                "budget_truncated": budget_truncated,
                "global_budget_incomplete": global_budget_incomplete,
            }
            record = _run_reporter(reporter, "record", record_request)
            validate_record(record)
            records.append(record)
    manifest = _run_reporter(reporter, "manifest", records)
    validate_manifest(manifest)
    _publish(Path(destination), serialize(manifest) + "\n", publisher)


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] == "run-report":
        # This command is the optional, post-legacy reporting boundary.  It
        # always returns the legacy status, including on reporter/publisher
        # failure, so diagnostics cannot alter legacy process semantics.
        arguments = argv[1:]
        options: dict[str, str] = {}
        while arguments:
            if len(arguments) < 2 or arguments[0] not in {
                "--requests",
                "--destination",
                "--provider",
                "--reporter",
                "--legacy-exit-status",
                "--publisher",
            }:
                print(
                    "spotify-qobuz-match-evidence: invalid run-report arguments",
                    file=sys.stderr,
                )
                return 2
            option, value = arguments[0], arguments[1]
            if option in options or not value:
                print(
                    "spotify-qobuz-match-evidence: invalid run-report arguments",
                    file=sys.stderr,
                )
                return 2
            options[option] = value
            arguments = arguments[2:]
        required = {
            "--requests",
            "--destination",
            "--provider",
            "--reporter",
            "--legacy-exit-status",
        }
        if not required <= set(options) or set(options) - (required | {"--publisher"}):
            print(
                "spotify-qobuz-match-evidence: invalid run-report arguments",
                file=sys.stderr,
            )
            return 2
        try:
            legacy_status = int(options["--legacy-exit-status"])
            if not 0 <= legacy_status <= 255:
                raise ValueError
        except ValueError:
            print(
                "spotify-qobuz-match-evidence: invalid legacy exit status",
                file=sys.stderr,
            )
            return 2
        try:
            run_reporting_path(
                options["--requests"],
                options["--destination"],
                options["--provider"],
                options["--reporter"],
                options.get("--publisher"),
            )
        except (EvidenceError, OSError, TypeError, ValueError) as exc:
            print(
                f"spotify-qobuz-match-evidence: warning: {exc}; preserving previous evidence report",
                file=sys.stderr,
            )
        return legacy_status
    try:
        if argv == ["queries"]:
            source = _source(_read_stdin())
            output = {
                "schema_version": SCHEMA_VERSION,
                "policy_version": POLICY_VERSION,
                "queries": plan_queries(source["album"], source["artist"]),
            }
        elif argv == ["record"]:
            output = build_record(_read_stdin())
        elif argv == ["manifest"]:
            records = _read_stdin()
            if not isinstance(records, list):
                raise EvidenceError("manifest input must be an array")
            output = build_manifest(records)
        elif len(argv) >= 4 and argv[0:2] == ["validate-destination", "--destination"]:
            destination = argv[2]
            if argv[3] != "--against" or len(argv) == 4:
                raise EvidenceError("validate-destination requires --against paths")
            validate_evidence_destination(destination, argv[4:])
            output = {"valid": True}
        else:
            raise EvidenceError(
                "expected queries, record, manifest, validate-destination, or run-report"
            )
    except (EvidenceError, KeyError, TypeError) as exc:
        print(f"spotify-qobuz-match-evidence: {exc}", file=sys.stderr)
        return 2
    print(serialize(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

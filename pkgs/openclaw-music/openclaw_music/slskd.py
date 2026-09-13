from __future__ import annotations

import http.client
import json
import re
import time
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import quote, urljoin, urlparse

from .deadline import DeadlineExpired, absolute_deadline, closing_create_connection
from .errors import (
    BackendNotFound,
    BackendPermanent,
    BackendTransient,
    BackendUncertain,
    Configuration,
    InvalidInput,
)

MAX_BODY = 2_000_000
HTTP_DEADLINE = 15.0
LOSSLESS = {"flac", "alac", "wav", "ape", "wv"}
LOSSY = {"mp3", "aac", "ogg", "m4a", "opus", "wma"}
FAILURES = {"aborted", "timedout", "rejected", "errored", "cancelled", "failed"}


def safe_remote_filename(value: object) -> str:
    if not isinstance(value, str) or not value or len(value) > 1024:
        raise InvalidInput("unsafe backend filename")
    if value.startswith(("/", "\\", "//", "\\\\")) or re.match(r"^[A-Za-z]:", value):
        raise InvalidInput("unsafe backend filename")
    parts = value.replace("\\", "/").split("/")
    if any(
        not part
        or part in {".", ".."}
        or any(ord(char) < 32 or ord(char) == 127 for char in part)
        for part in parts
    ):
        raise InvalidInput("unsafe backend filename")
    return "/".join(parts)


def state_flags(value: object) -> set[str]:
    if isinstance(value, list):
        values = value
    else:
        values = re.split(r"[,|;+]", str(value))
    return {str(item).strip().casefold() for item in values if str(item).strip()}


def transfer_failed(state: object) -> bool:
    return bool(state_flags(state) & FAILURES)


def transfer_succeeded(state: object) -> bool:
    flags = state_flags(state)
    return "completed" in flags and "succeeded" in flags and not transfer_failed(state)


def normalize_transfer_exception(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    message = " ".join(value.split())
    return message[:160] or None


def _integer(value: object, field: str) -> int:
    if type(value) is not int or value < 0:
        raise InvalidInput(f"invalid backend {field}")
    return value


def normalize_responses(value: object) -> list[dict]:
    if not isinstance(value, list):
        raise InvalidInput("invalid search responses")
    rows = []
    for peer in value:
        if (
            not isinstance(peer, dict)
            or not isinstance(peer.get("username"), str)
            or not peer["username"]
        ):
            continue
        queue = peer.get("queueLength", 0)
        if type(queue) is not int or queue < 0:
            continue
        free = peer.get("hasFreeUploadSlot", False)
        speed = peer.get("uploadSpeed", peer.get("speed", 0))
        if type(speed) is not int or speed < 0:
            speed = 0
        for locked, field in ((False, "files"), (True, "lockedFiles")):
            entries = peer.get(field, [])
            if not isinstance(entries, list):
                continue
            for item in entries:
                if not isinstance(item, dict):
                    continue
                try:
                    original = item["filename"]
                    remote = safe_remote_filename(original)
                    size = _integer(item["size"], "file size")
                except (KeyError, InvalidInput):
                    continue
                extension = item.get("extension")
                if not isinstance(extension, str):
                    extension = remote.rsplit(".", 1)[-1] if "." in remote else ""
                rows.append(
                    {
                        "peer": peer["username"],
                        "remote": remote,
                        "original_remote": original,
                        "size": size,
                        "locked": locked or bool(item.get("isLocked", False)),
                        "queue": queue,
                        "free_slot": bool(free),
                        "speed": speed,
                        "extension": extension.casefold(),
                        "length": item.get("length"),
                        "bit_rate": item.get("bitRate"),
                        "bit_depth": item.get("bitDepth"),
                    }
                )
    return rows


def normalize_transfers(value: object) -> list[dict]:
    if not isinstance(value, list):
        raise InvalidInput("invalid transfer listing")
    records = []
    for user in value:
        if not isinstance(user, dict) or not isinstance(user.get("username"), str):
            continue
        directories = user.get("directories")
        if not isinstance(directories, list):
            continue
        for directory in directories:
            if not isinstance(directory, dict) or not isinstance(
                directory.get("files"), list
            ):
                continue
            for item in directory["files"]:
                if not isinstance(item, dict):
                    continue
                try:
                    remote = safe_remote_filename(item["filename"])
                    size = _integer(item["size"], "transfer size")
                except (KeyError, InvalidInput):
                    continue
                transfer_id = item.get("id")
                if not isinstance(transfer_id, str) or not transfer_id:
                    continue
                timestamps = {
                    name: item.get(name)
                    for name in (
                        "requestedAt",
                        "enqueuedAt",
                        "startedAt",
                        "completedAt",
                    )
                }
                records.append(
                    {
                        "peer": user["username"],
                        "remote": remote,
                        "size": size,
                        "id": transfer_id,
                        "state": item.get("state", ""),
                        "bytes": item.get("bytesTransferred", item.get("bytes", 0)),
                        "timestamps": timestamps,
                        "batch_id": item.get(
                            "batchId", directory.get("batchId", user.get("batchId"))
                        ),
                        "exception": normalize_transfer_exception(
                            item.get("exception")
                        ),
                    }
                )
    return records


def _canonical_title(value: str) -> str:
    return re.sub(r"[^\w]+", "", value, flags=re.UNICODE)


def _source_title(value: str) -> str:
    stripped = re.sub(
        r"^[\s._-]*(?:cd|disc)?\s*\d{1,3}(?:[\s._-]+|$)", "", value.casefold()
    )
    return _canonical_title(stripped)


def _track_number(
    row: dict, manifest: list[dict]
) -> tuple[int | None, int | None, str]:
    pieces = row["remote"].split("/")
    stem = pieces[-1].rsplit(".", 1)[0]
    match = re.match(
        r"\s*(?:(?:disc|cd)\s*(\d+)\D+)?(\d{1,3})(?:\D|$)", stem, re.IGNORECASE
    )
    track = int(match.group(2)) if match else None
    disc = int(match.group(1)) if match and match.group(1) else None
    if disc is None:
        for piece in reversed(pieces[:-1]):
            found = re.fullmatch(r"(?:disc|cd)\s*(\d+)", piece, re.IGNORECASE)
            if found:
                disc = int(found.group(1))
                break
    if disc is None and len({item["disc"] for item in manifest}) == 1:
        disc = manifest[0]["disc"]
    return disc, track, _source_title(stem)


def source_offers(rows: list[dict], manifest: list[dict]) -> list[dict]:
    grouped: dict[tuple[str, str], list[dict]] = {}
    for row in rows:
        parent_parts = row["remote"].split("/")[:-1]
        if parent_parts and re.fullmatch(
            r"(?:cd|disc)\s*\d+", parent_parts[-1], re.IGNORECASE
        ):
            parent_parts = parent_parts[:-1]
        parent = "/".join(parent_parts)
        grouped.setdefault((row["peer"], parent), []).append(row)
    expected = {(item["disc"], item["track"]): item for item in manifest}
    offers = []
    for (peer, directory), files in grouped.items():
        mapping = {}
        invalid = False
        for row in files:
            if row["extension"] not in LOSSLESS | LOSSY:
                continue
            if row["locked"]:
                invalid = True
                continue
            disc, track, title = _track_number(row, manifest)
            key = (disc, track)
            expected_track = expected.get(key)
            if expected_track is None or key in mapping:
                invalid = True
                continue
            expected_title = _canonical_title(expected_track["title"].casefold())
            if not title or not expected_title or title != expected_title:
                invalid = True
                continue
            mapping[key] = row
        complete = not invalid and set(mapping) == set(expected) and bool(mapping)
        selected = [
            {**mapping[key], "disc": key[0], "track": key[1]} for key in sorted(mapping)
        ]
        all_lossless = complete and all(
            row["extension"] in LOSSLESS for row in selected
        )
        offers.append(
            {
                "peer": peer,
                "directory": directory,
                "files": selected,
                "complete": complete,
                "all_lossless": all_lossless,
                "quality": "lossless" if all_lossless else "lossy",
                "free_slot": all(row["free_slot"] for row in selected),
                "queue": max((row["queue"] for row in selected), default=999999),
                "speed": min((row["speed"] for row in selected), default=0),
            }
        )
    return offers


def rank_offers(offers: list[dict], policy: dict) -> tuple[dict | None, list[dict]]:
    acceptable = [offer for offer in offers if offer["complete"]]
    if not acceptable:
        return None, []
    lossless = [offer for offer in acceptable if offer["all_lossless"]]
    if policy["profile"] == "lossless" or lossless:
        acceptable = lossless
    elif not policy.get("accepted_lossy"):
        return None, [offer for offer in acceptable]

    def score(offer: dict) -> tuple:
        return (
            offer["all_lossless"],
            offer["free_slot"],
            -offer["queue"],
            offer["speed"],
        )

    acceptable.sort(
        key=lambda offer: (score(offer), offer["peer"], offer["directory"]),
        reverse=True,
    )
    top = acceptable[0]
    equivalent = [offer for offer in acceptable if score(offer) == score(top)]
    if len(equivalent) > 1:
        return None, equivalent
    return top, []


class HttpTransport:
    """Bounded loopback-only slskd transport with no ambient proxy configuration."""

    def __init__(self, base_url: str, api_key: str, *, deadline: float = HTTP_DEADLINE):
        parsed = urlparse(base_url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise Configuration("invalid slskd origin")
        self.base_url = base_url.rstrip("/")
        self.origin = (parsed.scheme, parsed.hostname.casefold(), parsed.port)
        self.api_key = api_key
        self.deadline = deadline

    @staticmethod
    def _remaining(started: float, deadline: float) -> float:
        remaining = deadline - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError("HTTP deadline exceeded")
        return remaining

    def __call__(self, method: str, path: str, body: bytes | None = None):
        url = urljoin(self.base_url + "/", path.lstrip("/"))
        parsed = urlparse(url)
        if (
            parsed.scheme,
            parsed.hostname.casefold() if parsed.hostname else "",
            parsed.port,
        ) != self.origin:
            raise BackendPermanent("cross-origin slskd request refused")
        headers = {
            "X-API-Key": self.api_key,
            "Accept": "application/json",
            **({"Content-Type": "application/json"} if body is not None else {}),
        }
        mutation = method in {"POST", "DELETE", "PUT", "PATCH"}
        connection = None
        response = None
        try:
            with absolute_deadline(self.deadline):
                started = time.monotonic()
                connection_class = (
                    http.client.HTTPSConnection
                    if parsed.scheme == "https"
                    else http.client.HTTPConnection
                )
                connection = connection_class(
                    parsed.hostname,
                    parsed.port,
                    timeout=self._remaining(started, self.deadline),
                )
                connection._create_connection = closing_create_connection
                request_path = (parsed.path or "/") + (
                    ("?" + parsed.query) if parsed.query else ""
                )
                connection.request(method, request_path, body=body, headers=headers)
                response = connection.getresponse()
                if 300 <= response.status < 400:
                    raise BackendPermanent("slskd redirect refused")
                if response.status == 404:
                    raise BackendNotFound("slskd resource was not found")
                if 400 <= response.status < 500:
                    raise BackendPermanent(
                        f"slskd rejected request ({response.status})",
                        detail={"definitively_non_mutating": mutation},
                    )
                if response.status >= 500:
                    error = BackendUncertain if mutation else BackendTransient
                    raise error(f"slskd HTTP failure ({response.status})")
                chunks = []
                size = 0
                while True:
                    chunk = response.read(min(65_536, MAX_BODY + 1 - size))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    size += len(chunk)
                    if size > MAX_BODY:
                        raise BackendTransient("slskd response too large")
                raw = b"".join(chunks)
                if response.status == 204 or not raw:
                    return None
                try:
                    return json.loads(raw)
                except json.JSONDecodeError:
                    error = BackendUncertain if mutation else BackendPermanent
                    raise error("slskd returned invalid JSON") from None
        except (BackendPermanent, BackendNotFound, BackendTransient, BackendUncertain):
            raise
        except (
            DeadlineExpired,
            http.client.HTTPException,
            TimeoutError,
            OSError,
        ) as exc:
            error = BackendUncertain if mutation else BackendTransient
            raise error("slskd unavailable") from exc
        finally:
            if response is not None:
                try:
                    response.close()
                except OSError:
                    pass
            if connection is not None:
                connection.close()


def api_key_from_file(path: str) -> str:
    try:
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            name, separator, value = line.partition("=")
            if name == "SLSKD_API_KEY" and separator and value.strip():
                return value.strip().strip("\"'")
    except OSError as exc:
        raise Configuration("cannot read slskd secret file") from exc
    raise Configuration("SLSKD_API_KEY is absent")


class SlskdClient:
    def __init__(self, base_url: str, api_key: str, transport=None):
        self.transport = transport or HttpTransport(base_url, api_key)

    def call(self, method: str, path: str, body: bytes | None = None):
        return self.transport(method, path, body)

    def create_search(self, search_id: str, search_text: str) -> None:
        result = self.call(
            "POST",
            "/api/v0/searches",
            json.dumps({"id": search_id, "searchText": search_text}).encode("utf-8"),
        )
        if not isinstance(result, dict) or result.get("id") != search_id:
            raise BackendPermanent("slskd search response id does not match intent")

    def search_status(self, search_id: str) -> dict:
        result = self.call("GET", "/api/v0/searches/" + quote(search_id, safe=""))
        if not isinstance(result, dict):
            raise BackendPermanent("invalid slskd search status")
        return result

    def search_complete(self, search_id: str) -> bool:
        status = self.search_status(search_id)
        state = str(status.get("state", "")).casefold()
        return state in {"completed", "complete"} or status.get("isComplete") is True

    def responses(self, search_id: str) -> list[dict]:
        result = self.call(
            "GET", "/api/v0/searches/" + quote(search_id, safe="") + "/responses"
        )
        return normalize_responses([] if result is None else result)

    def delete_search(self, search_id: str) -> None:
        self.call("DELETE", "/api/v0/searches/" + quote(search_id, safe=""))

    def queue(
        self, peer: str, files: list[dict], *, batch_id: str, search_id: str
    ) -> None:
        body = {
            "username": peer,
            "id": batch_id,
            "searchId": search_id,
            "options": {"destination": f"openclaw/{batch_id}", "externalId": batch_id},
            "files": [
                {"filename": item["original_remote"], "size": item["size"]}
                for item in files
            ],
        }
        result = self.call(
            "POST",
            "/api/v0/transfers/downloads/batches",
            json.dumps(body).encode("utf-8"),
        )
        if isinstance(result, dict):
            batch = result.get("batch")
            failures = result.get("failures", [])
            if (
                not isinstance(batch, dict)
                or batch.get("id") != batch_id
                or not isinstance(failures, list)
            ):
                raise BackendPermanent(
                    "invalid slskd batch queue response",
                    detail={"batch_response": str(result)[:240]},
                )
            if failures:
                details = []
                for failure in failures[:20]:
                    if isinstance(failure, dict):
                        details.append(
                            f"{str(failure.get('filename', '?'))[:80]}: {str(failure.get('message', '?'))[:120]}"
                        )
                raise BackendPermanent(
                    "slskd batch queue reported failure",
                    detail={"batch_response": "; ".join(details)[:240]},
                )
        elif result is not None:
            raise BackendPermanent("invalid slskd batch queue response")

    def transfers(self) -> list[dict]:
        return normalize_transfers(self.call("GET", "/api/v0/transfers/downloads"))


def timestamp_after(value: object, intent: str) -> bool:
    if not isinstance(value, str):
        return False
    try:
        candidate = datetime.fromisoformat(value)
        started = datetime.fromisoformat(intent)
    except ValueError:
        return False
    if candidate.tzinfo is None:
        candidate = candidate.replace(tzinfo=UTC)
    if started.tzinfo is None:
        started = started.replace(tzinfo=UTC)
    return candidate >= started

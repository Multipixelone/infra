from __future__ import annotations

import json
from typing import Any

from .errors import InvalidInput
from .models import parse_uuid

MAX_INPUT = 65_536
MAX_TEXT = 512
MAX_DEPTH = 12
MAX_ITEMS = 128
PROFILES = {"lossless", "lossless-preferred"}


def _pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidInput("duplicate JSON key")
        result[key] = value
    return result


def _bounded(value: Any, depth: int = 0) -> None:
    if depth > MAX_DEPTH:
        raise InvalidInput("JSON nesting is too deep")
    if isinstance(value, dict):
        if len(value) > MAX_ITEMS:
            raise InvalidInput("JSON object has too many fields")
        for key, child in value.items():
            if not isinstance(key, str):
                raise InvalidInput("JSON object key is invalid")
            _bounded(child, depth + 1)
    elif isinstance(value, list):
        if len(value) > MAX_ITEMS:
            raise InvalidInput("JSON array has too many items")
        for child in value:
            _bounded(child, depth + 1)
    elif isinstance(value, str):
        _unicode(value, "JSON string")


def _unicode(value: str, field: str) -> None:
    if any(
        ord(char) < 32 or ord(char) == 127 or 0xD800 <= ord(char) <= 0xDFFF
        for char in value
    ):
        raise InvalidInput(f"{field} contains unsafe Unicode")


def load_json(raw: bytes | str) -> dict[str, Any]:
    if isinstance(raw, bytes):
        if len(raw) > MAX_INPUT:
            raise InvalidInput("input is too large")
        try:
            raw = raw.decode("utf-8")
        except UnicodeDecodeError:
            raise InvalidInput("input is not UTF-8") from None
    if not isinstance(raw, str):
        raise InvalidInput("input must be UTF-8 JSON")
    if len(raw.encode("utf-8", "surrogatepass")) > MAX_INPUT:
        raise InvalidInput("input is too large")
    try:
        data = json.loads(raw, object_pairs_hook=_pairs)
    except InvalidInput:
        raise
    except (json.JSONDecodeError, TypeError, UnicodeEncodeError):
        raise InvalidInput("malformed JSON") from None
    _bounded(data)
    if not isinstance(data, dict):
        raise InvalidInput("input must be a JSON object")
    return data


def _text(value: Any, field: str, required: bool = True) -> str | None:
    if value is None and not required:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > MAX_TEXT:
        raise InvalidInput(f"{field} must be a non-blank string")
    _unicode(value, field)
    return value.strip()


def _fields(data: dict, allowed: set[str], required: set[str]) -> None:
    extra = set(data) - allowed
    missing = required - set(data)
    if extra:
        raise InvalidInput("unknown field: " + min(extra))
    if missing:
        raise InvalidInput("missing field: " + min(missing))
    if type(data.get("schema")) is not int or data["schema"] != 1:
        raise InvalidInput("unsupported schema")


def _request(command: str, data: dict) -> dict:
    common = {"schema"}
    fields = {
        "artist",
        "release",
        "edition",
        "medium",
        "include_live",
        "include_compilations",
    }
    if command == "submit":
        fields |= {"idempotency_key", "quality_profile"}
    required = (
        {"idempotency_key", "artist", "release"}
        if command == "submit"
        else {"artist", "release"}
    )
    _fields(data, common | fields, common | required)
    output = {name: _text(data[name], name) for name in ("artist", "release")}
    if command == "submit":
        output["idempotency_key"] = _text(data["idempotency_key"], "idempotency_key")
        if "quality_profile" in data:
            profile = data["quality_profile"]
            if not isinstance(profile, str) or profile not in PROFILES:
                raise InvalidInput("unsupported quality_profile")
            output["quality_profile"] = profile
    for name in ("edition", "medium"):
        if name in data:
            output[name] = _text(data[name], name, False)
    for name in ("include_live", "include_compilations"):
        if name in data and type(data[name]) is not bool:
            raise InvalidInput(f"{name} must be boolean")
        output[name] = data.get(name, False)
    return output


def parse(command: str, data: dict) -> dict:
    if command in {"resolve", "submit"}:
        return _request(command, data)
    if command == "choose":
        allowed = {"schema", "job_id", "candidate_set_id", "candidate_id", "revision"}
        _fields(data, allowed, allowed)
        if type(data["revision"]) is not int or data["revision"] < 1:
            raise InvalidInput("revision must be a positive integer")
        return {
            "job_id": parse_uuid(data["job_id"]),
            "candidate_set_id": _text(data["candidate_set_id"], "candidate_set_id"),
            "candidate_id": _text(data["candidate_id"], "candidate_id"),
            "revision": data["revision"],
        }
    if command in {"status", "retry"}:
        _fields(data, {"schema", "job_id"}, {"schema", "job_id"})
        return {"job_id": parse_uuid(data["job_id"])}
    if command == "worker":
        _fields(data, {"schema"}, {"schema"})
        return {}
    raise InvalidInput("unsupported command")

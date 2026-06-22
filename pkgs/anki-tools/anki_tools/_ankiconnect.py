"""Minimal AnkiConnect client (stdlib only).

AnkiConnect exposes Anki over HTTP at http://127.0.0.1:8765. Every request is a
POST with body {"action", "version": 6, "params"} and the response is
{"result", "error"}.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request

DEFAULT_ENDPOINT = "http://127.0.0.1:8765"
API_VERSION = 6


class AnkiConnectError(RuntimeError):
    """An AnkiConnect call returned a non-null ``error`` or was unreachable."""


def invoke(
    action: str,
    params: dict | None = None,
    endpoint: str = DEFAULT_ENDPOINT,
    timeout: float = 10.0,
):
    """Call an AnkiConnect ``action`` and return its ``result``.

    Raises AnkiConnectError if Anki/AnkiConnect is unreachable or returns an
    error.
    """
    payload = json.dumps(
        {"action": action, "version": API_VERSION, "params": params or {}}
    ).encode("utf-8")
    request = urllib.request.Request(
        endpoint, data=payload, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = json.load(response)
    except urllib.error.URLError as e:
        raise AnkiConnectError(
            f"cannot reach AnkiConnect at {endpoint}: {e}. "
            "Is Anki running with the AnkiConnect add-on installed?"
        ) from e

    if not isinstance(data, dict) or "error" not in data or "result" not in data:
        raise AnkiConnectError(f"unexpected AnkiConnect response: {data!r}")
    if data["error"] is not None:
        raise AnkiConnectError(data["error"])
    return data["result"]

"""Shared helpers: cards.json loading/validation, stable IDs, cloze parsing.

This module is deliberately dependency-free (stdlib only) so that the
AnkiConnect entry points work even where genanki is unavailable.
"""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

# genanki requires model/deck IDs in the half-open range [1<<30, 1<<31).
_ID_LO = 1 << 30
_ID_HI = 1 << 31

# Anki cloze markers look like {{c1::answer}} or {{c1::answer::hint}}.
_CLOZE_NUM_RE = re.compile(r"\{\{c(\d+)::")

NOTE_TYPES = ("basic", "reversed", "cloze")


class CardError(ValueError):
    """Raised for malformed cards.json input, with a human-readable message."""


def stable_id(seed: str) -> int:
    """Deterministic genanki id in [1<<30, 1<<31) derived from a seed string.

    Using a fixed seed keeps deck/model IDs stable across runs so re-importing a
    rebuilt deck updates the existing notes rather than creating duplicates.
    """
    h = int(hashlib.md5(seed.encode()).hexdigest(), 16)
    return _ID_LO + (h % (_ID_HI - _ID_LO))


def cloze_numbers(text: str) -> list[int]:
    """Return the sorted unique cloze indices (1 for c1, 2 for c2, ...) in text."""
    return sorted({int(m.group(1)) for m in _CLOZE_NUM_RE.finditer(text)})


def sanitize_tag(tag: str) -> str:
    """Anki tags cannot contain whitespace; collapse runs to underscores."""
    return re.sub(r"\s+", "_", str(tag).strip())


def _require(cond: bool, msg: str) -> None:
    if not cond:
        raise CardError(msg)


def load_cards(path: str | Path) -> dict:
    """Load and validate a cards.json file into a normalized structure:

        {
          "deck": str,
          "tags": [str],
          "media_root": Path,   # directory media paths are resolved against
          "notes": [ <note>, ... ],
        }

    where each <note> is one of:

        {"type": "basic"|"reversed", "front", "back", "extra", "tags", "media"}
        {"type": "cloze",            "text",          "extra", "tags", "media"}
    """
    path = Path(path)
    _require(path.is_file(), f"cards file not found: {path}")
    try:
        raw = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        raise CardError(f"{path}: invalid JSON: {e}") from e

    _require(isinstance(raw, dict), "top level of cards.json must be a JSON object")

    deck = raw.get("deck", "Default")
    _require(
        isinstance(deck, str) and deck.strip(),
        "'deck' must be a non-empty string",
    )

    deck_tags = raw.get("tags", [])
    _require(isinstance(deck_tags, list), "'tags' must be a list of strings")

    notes_raw = raw.get("notes")
    _require(
        isinstance(notes_raw, list) and notes_raw,
        "'notes' must be a non-empty list",
    )

    notes = [_normalize_note(i, n, deck_tags) for i, n in enumerate(notes_raw)]

    return {
        "deck": deck.strip(),
        "tags": [sanitize_tag(t) for t in deck_tags],
        "media_root": path.resolve().parent,
        "notes": notes,
    }


def _normalize_note(idx: int, note: dict, deck_tags: list) -> dict:
    where = f"notes[{idx}]"
    _require(isinstance(note, dict), f"{where} must be an object")

    ntype = note.get("type")
    _require(
        ntype in NOTE_TYPES,
        f"{where}: 'type' must be one of {NOTE_TYPES}, got {ntype!r}",
    )

    # Merge per-note tags with deck-level tags, de-duplicating, preserving order.
    raw_tags = [*note.get("tags", []), *deck_tags]
    tags = list(dict.fromkeys(sanitize_tag(t) for t in raw_tags if str(t).strip()))

    media = note.get("media", [])
    _require(isinstance(media, list), f"{where}: 'media' must be a list of paths")
    media = [str(m) for m in media]

    extra = str(note.get("extra", "") or "")

    if ntype in ("basic", "reversed"):
        front = note.get("front")
        back = note.get("back")
        _require(
            isinstance(front, str) and front.strip(),
            f"{where}: '{ntype}' needs a non-empty 'front'",
        )
        _require(
            isinstance(back, str) and back.strip(),
            f"{where}: '{ntype}' needs a non-empty 'back'",
        )
        return {
            "type": ntype,
            "front": front,
            "back": back,
            "extra": extra,
            "tags": tags,
            "media": media,
        }

    # cloze
    text = note.get("text")
    _require(
        isinstance(text, str) and text.strip(),
        f"{where}: 'cloze' needs a non-empty 'text'",
    )
    _require(
        cloze_numbers(text),
        f"{where}: 'cloze' text has no {{{{cN::...}}}} deletions: {text!r}",
    )
    return {
        "type": "cloze",
        "text": text,
        "extra": extra,
        "tags": tags,
        "media": media,
    }

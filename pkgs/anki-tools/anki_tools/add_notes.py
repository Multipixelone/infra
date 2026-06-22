"""anki-add-notes: push a cards.json file into a running Anki via AnkiConnect.

Uses Anki's built-in note types (Basic, Basic (and reversed card), Cloze) so the
cards look native. Because Basic has no Extra field, a note's ``extra`` is
appended to the Back; the Cloze note type's native "Back Extra" field is used for
cloze extras.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from ._ankiconnect import DEFAULT_ENDPOINT, AnkiConnectError, invoke
from ._common import CardError, load_cards

_MODEL_BASIC = "Basic"
_MODEL_REVERSED = "Basic (and reversed card)"
_MODEL_CLOZE = "Cloze"


def _ac_note(card: dict, deck_name: str, allow_duplicate: bool) -> dict:
    if card["type"] == "cloze":
        fields = {"Text": card["text"]}
        if card["extra"]:
            fields["Back Extra"] = card["extra"]
        model = _MODEL_CLOZE
    else:
        back = card["back"]
        if card["extra"]:
            back += f'<br><div class="extra">{card["extra"]}</div>'
        fields = {"Front": card["front"], "Back": back}
        model = _MODEL_REVERSED if card["type"] == "reversed" else _MODEL_BASIC

    return {
        "deckName": deck_name,
        "modelName": model,
        "fields": fields,
        "tags": card["tags"],
        "options": {"allowDuplicate": allow_duplicate},
    }


def _store_media(data: dict, endpoint: str) -> None:
    for card in data["notes"]:
        for rel in card["media"]:
            path = (data["media_root"] / rel).resolve()
            if not path.is_file():
                print(f"warning: media file not found, skipping: {path}", file=sys.stderr)
                continue
            invoke("storeMediaFile", {"filename": path.name, "path": str(path)}, endpoint)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="anki-add-notes",
        description="Push a cards.json file into a running Anki via AnkiConnect.",
    )
    parser.add_argument("cards", help="path to a cards.json file")
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT, help="AnkiConnect URL")
    parser.add_argument(
        "--allow-duplicate",
        action="store_true",
        help="add notes even if Anki considers them duplicates",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the addNotes payload without contacting Anki",
    )
    args = parser.parse_args(argv)

    try:
        data = load_cards(args.cards)
    except CardError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    notes = [_ac_note(c, data["deck"], args.allow_duplicate) for c in data["notes"]]

    if args.dry_run:
        payload = {"action": "addNotes", "version": 6, "params": {"notes": notes}}
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    try:
        invoke("version", endpoint=args.endpoint)
        invoke("createDeck", {"deck": data["deck"]}, args.endpoint)
        _store_media(data, args.endpoint)

        addable_flags = invoke("canAddNotes", {"notes": notes}, args.endpoint)
        addable = [n for n, ok in zip(notes, addable_flags) if ok]
        skipped = len(notes) - len(addable)

        results = invoke("addNotes", {"notes": addable}, args.endpoint) if addable else []
    except AnkiConnectError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    added = sum(1 for r in results if r)
    failed = len(addable) - added
    msg = f"Added {added} note(s) to '{data['deck']}'"
    if skipped:
        msg += f", skipped {skipped} duplicate/invalid"
    if failed:
        msg += f", {failed} failed"
    print(msg + ".")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

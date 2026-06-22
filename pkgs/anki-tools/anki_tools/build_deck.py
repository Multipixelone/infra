"""anki-build-deck: build a portable .apkg deck from a cards.json file."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import genanki

from ._common import CardError, load_cards, stable_id

# Shared styling for all generated note types.
_CSS = """
.card {
  font-family: -apple-system, system-ui, "Segoe UI", sans-serif;
  font-size: 20px;
  line-height: 1.5;
  text-align: center;
  color: #1a1a1a;
  background-color: #ffffff;
}
.extra {
  font-size: 15px;
  color: #555;
  margin-top: 0.7em;
}
.cloze {
  font-weight: bold;
  color: #1565c0;
}
"""

_QA_AFMT = (
    '{{FrontSide}}<hr id="answer">{{%s}}'
    '{{#Extra}}<div class="extra">{{Extra}}</div>{{/Extra}}'
)

# Fixed model IDs (via stable_id) so re-importing a rebuilt deck updates the same
# note types instead of spawning duplicates.
BASIC_MODEL = genanki.Model(
    model_id=stable_id("anki-tools/model/basic/v1"),
    name="anki-tools Basic",
    fields=[{"name": "Front"}, {"name": "Back"}, {"name": "Extra"}],
    templates=[
        {"name": "Card 1", "qfmt": "{{Front}}", "afmt": _QA_AFMT % "Back"},
    ],
    css=_CSS,
)

REVERSED_MODEL = genanki.Model(
    model_id=stable_id("anki-tools/model/reversed/v1"),
    name="anki-tools Basic (and reversed card)",
    fields=[{"name": "Front"}, {"name": "Back"}, {"name": "Extra"}],
    templates=[
        {"name": "Card 1", "qfmt": "{{Front}}", "afmt": _QA_AFMT % "Back"},
        {"name": "Card 2", "qfmt": "{{Back}}", "afmt": _QA_AFMT % "Front"},
    ],
    css=_CSS,
)

CLOZE_MODEL = genanki.Model(
    model_id=stable_id("anki-tools/model/cloze/v1"),
    name="anki-tools Cloze",
    model_type=genanki.Model.CLOZE,
    fields=[{"name": "Text"}, {"name": "Extra"}],
    templates=[
        {
            "name": "Cloze",
            "qfmt": "{{cloze:Text}}",
            "afmt": (
                "{{cloze:Text}}"
                '{{#Extra}}<div class="extra">{{Extra}}</div>{{/Extra}}'
            ),
        }
    ],
    css=_CSS,
)


def _note_for(card: dict, deck_name: str) -> genanki.Note:
    """Build a genanki.Note with a deterministic GUID for stable re-imports.

    The GUID is keyed on the *prompt* side (front, or full cloze text) so that
    editing the answer of a Basic card updates the same note on re-import.
    """
    if card["type"] == "cloze":
        guid = genanki.guid_for(f"{deck_name}|cloze|{card['text']}")
        return genanki.Note(
            model=CLOZE_MODEL,
            fields=[card["text"], card["extra"]],
            tags=card["tags"],
            guid=guid,
        )

    model = BASIC_MODEL if card["type"] == "basic" else REVERSED_MODEL
    guid = genanki.guid_for(f"{deck_name}|{card['type']}|{card['front']}")
    return genanki.Note(
        model=model,
        fields=[card["front"], card["back"], card["extra"]],
        tags=card["tags"],
        guid=guid,
    )


def _default_output(deck_name: str) -> str:
    safe = deck_name.replace("::", "__").replace(" ", "_")
    return f"{safe}.apkg"


def build(data: dict, output: Path) -> int:
    deck = genanki.Deck(
        deck_id=stable_id(f"anki-tools/deck/{data['deck']}"),
        name=data["deck"],
    )

    media_files: list[str] = []
    for card in data["notes"]:
        deck.add_note(_note_for(card, data["deck"]))
        for rel in card["media"]:
            path = (data["media_root"] / rel).resolve()
            if not path.is_file():
                print(f"warning: media file not found, skipping: {path}", file=sys.stderr)
                continue
            media_files.append(str(path))

    package = genanki.Package(deck)
    package.media_files = sorted(set(media_files))
    package.write_to_file(str(output))
    return len(data["notes"])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="anki-build-deck",
        description="Build a portable .apkg deck from a cards.json file.",
    )
    parser.add_argument("cards", help="path to a cards.json file")
    parser.add_argument(
        "output",
        nargs="?",
        help="output .apkg path (default: <deck-name>.apkg)",
    )
    args = parser.parse_args(argv)

    try:
        data = load_cards(args.cards)
    except CardError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    output = Path(args.output) if args.output else Path(_default_output(data["deck"]))
    n = build(data, output)
    print(f"Wrote {n} note(s) to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

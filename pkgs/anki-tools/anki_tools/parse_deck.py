"""anki-parse-deck: extract a .apkg back into cards.json for round-trip editing.

Reads the SQLite collection inside the .apkg (stdlib only) and maps notes back
to the shared schema. Handles the legacy ``collection.anki2`` schema written by
genanki/older Anki and the ``collection.anki21`` schema. The newest zstd-packed
``collection.anki21b`` export format is not supported; re-export with "Support
older Anki versions" enabled if you hit that.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import tempfile
import zipfile
from pathlib import Path

# Anki separates the fields of a note with the unit-separator control char.
_FIELD_SEP = "\x1f"


def _extract_db(apkg: Path, dest: Path) -> Path:
    with zipfile.ZipFile(apkg) as zf:
        names = set(zf.namelist())
        for candidate in ("collection.anki21", "collection.anki2"):
            if candidate in names:
                zf.extract(candidate, dest)
                return dest / candidate
        if "collection.anki21b" in names:
            raise SystemExit(
                "error: this .apkg uses the new packed format (collection.anki21b),"
                " which is not supported. Re-export with 'Support older Anki"
                " versions' enabled."
            )
    raise SystemExit("error: no collection database found inside the .apkg")


def _models(cur: sqlite3.Cursor) -> dict[int, dict]:
    """Return {mid: {"name": str, "is_cloze": bool, "n_templates": int}}."""
    # Legacy schema: a single JSON blob in col.models.
    try:
        row = cur.execute("SELECT models FROM col").fetchone()
    except sqlite3.OperationalError:
        row = None
    if row and row[0]:
        out = {}
        for mid, m in json.loads(row[0]).items():
            out[int(mid)] = {
                "name": m.get("name", ""),
                "is_cloze": m.get("type", 0) == 1,
                "n_templates": len(m.get("tmpls", []) or []),
            }
        if out:
            return out

    # Modern schema: notetypes + templates tables.
    out = {}
    for mid, name, mtype in cur.execute("SELECT id, name, type FROM notetypes"):
        n_tmpl = cur.execute(
            "SELECT COUNT(*) FROM templates WHERE ntid = ?", (mid,)
        ).fetchone()[0]
        out[int(mid)] = {
            "name": name,
            "is_cloze": mtype == 1,
            "n_templates": n_tmpl,
        }
    return out


def _deck_names(cur: sqlite3.Cursor) -> dict[int, str]:
    try:
        row = cur.execute("SELECT decks FROM col").fetchone()
        if row and row[0]:
            return {int(did): d.get("name", "") for did, d in json.loads(row[0]).items()}
    except sqlite3.OperationalError:
        pass
    try:
        return {int(did): name for did, name in cur.execute("SELECT id, name FROM decks")}
    except sqlite3.OperationalError:
        return {}


def parse(apkg: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix="anki_parse_") as tmp:
        db = _extract_db(apkg, Path(tmp))
        con = sqlite3.connect(db)
        try:
            cur = con.cursor()
            models = _models(cur)
            deck_names = _deck_names(cur)

            # Pick the most common non-"Default" deck as the deck name.
            deck_counts: dict[str, int] = {}
            for (did,) in cur.execute("SELECT DISTINCT did FROM cards"):
                name = deck_names.get(int(did), "")
                if name and name != "Default":
                    deck_counts[name] = deck_counts.get(name, 0) + 1
            deck = max(deck_counts, key=deck_counts.get) if deck_counts else "Default"

            notes = []
            for mid, flds, tags in cur.execute("SELECT mid, flds, tags FROM notes"):
                model = models.get(int(mid), {})
                fields = flds.split(_FIELD_SEP)
                tag_list = [t for t in tags.split(" ") if t]
                notes.append(_note_to_schema(model, fields, tag_list))
        finally:
            con.close()

    return {"deck": deck, "tags": [], "notes": notes}


def _note_to_schema(model: dict, fields: list[str], tags: list[str]) -> dict:
    extra = fields[2] if len(fields) > 2 else ""
    if model.get("is_cloze"):
        note = {"type": "cloze", "text": fields[0] if fields else ""}
        cloze_extra = fields[1] if len(fields) > 1 else ""
        if cloze_extra:
            note["extra"] = cloze_extra
    else:
        ntype = "reversed" if model.get("n_templates", 1) >= 2 else "basic"
        note = {
            "type": ntype,
            "front": fields[0] if fields else "",
            "back": fields[1] if len(fields) > 1 else "",
        }
        if extra:
            note["extra"] = extra
    if tags:
        note["tags"] = tags
    return note


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="anki-parse-deck",
        description="Extract a .apkg into cards.json (printed to stdout).",
    )
    parser.add_argument("apkg", help="path to a .apkg file")
    parser.add_argument(
        "-o",
        "--output",
        help="write JSON here instead of stdout",
    )
    args = parser.parse_args(argv)

    apkg = Path(args.apkg)
    if not apkg.is_file():
        print(f"error: file not found: {apkg}", file=sys.stderr)
        return 1

    data = parse(apkg)
    text = json.dumps(data, indent=2, ensure_ascii=False)
    if args.output:
        Path(args.output).write_text(text + "\n")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

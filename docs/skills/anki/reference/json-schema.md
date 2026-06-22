# `cards.json` schema

The single card format consumed by every `anki-tools` command
(`anki-build-deck`, `anki-add-notes`). Author cards as one JSON object.

```json
{
  "deck": "Biology::Cell",
  "tags": ["bio", "exam1"],
  "notes": [
    {
      "type": "basic",
      "front": "What enzyme unwinds DNA at the replication fork?",
      "back": "Helicase",
      "extra": "It breaks hydrogen bonds between base pairs.",
      "tags": ["replication"]
    },
    {
      "type": "reversed",
      "front": "perro",
      "back": "dog"
    },
    {
      "type": "cloze",
      "text": "The {{c1::mitochondrion}} produces most of the cell's {{c2::ATP}}.",
      "extra": "Via oxidative phosphorylation.",
      "media": ["mitochondrion.png"]
    }
  ]
}
```

## Top-level fields

| Field   | Required | Meaning |
|---------|----------|---------|
| `deck`  | no (default `"Default"`) | Deck name. Use `::` for sub-decks, e.g. `"Spanish::Verbs"`. |
| `tags`  | no | Tags applied to **every** note, merged with each note's own `tags`. |
| `notes` | **yes** | Non-empty list of note objects. |

## Note objects

Every note has a `type` of `"basic"`, `"reversed"`, or `"cloze"`.

**Common optional keys** (all types):
- `extra` — supplementary text shown under the answer (e.g. a mnemonic, source).
- `tags` — list of tags for this note (merged with top-level `tags`). Whitespace
  in a tag is converted to `_` (Anki forbids spaces in tags).
- `media` — list of file paths referenced by the note, resolved **relative to the
  `cards.json` file**. Reference them by **basename** in the HTML, e.g.
  `"front": "<img src=\"mitochondrion.png\">"` with `"media": ["mitochondrion.png"]`.

**`basic`** and **`reversed`** require:
- `front` — the prompt (non-empty).
- `back` — the answer (non-empty).

`reversed` additionally generates the back→front card. Only use it when both
directions are unambiguous (see `card-writing.md`).

**`cloze`** requires:
- `text` — contains at least one `{{c1::answer}}` (or `{{c1::answer::hint}}`)
  deletion. Use `c1`, `c2`, … to control card grouping (same number = one card,
  different numbers = separate cards).

## Notes & behavior

- **HTML is allowed** in `front`/`back`/`text`/`extra` (`<b>`, `<br>`, `<img>`,
  `<ul>`, …). Escape literal `<`, `>`, `&` as `&lt; &gt; &amp;`.
- **Stable IDs / dedup**: `anki-build-deck` derives deterministic note GUIDs from
  the prompt side, so rebuilding and re-importing **updates** existing notes
  instead of duplicating. `anki-add-notes` uses AnkiConnect's `canAddNotes` to
  skip duplicates (override with `--allow-duplicate`).
- **Extra field caveat for AnkiConnect**: Anki's built-in *Basic* note type has
  no Extra field, so `anki-add-notes` appends `extra` to the Back for
  basic/reversed; for cloze it uses the native "Back Extra" field. The
  `.apkg` path (`anki-build-deck`) uses dedicated Extra fields on all types.

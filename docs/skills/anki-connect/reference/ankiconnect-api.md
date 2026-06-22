# AnkiConnect API reference

AnkiConnect exposes Anki over HTTP at `http://127.0.0.1:8765` while Anki desktop
is running. Every request is an HTTP POST with a JSON body:

```json
{ "action": "<name>", "version": 6, "params": { } }
```

and every response has the shape:

```json
{ "result": <value>, "error": null }
```

`error` is `null` on success or a string message on failure. The `anki-connect`
command wraps all of this — `anki-connect <action> '<json-params>'` — but the raw
actions are documented here for when you need one the helper scripts don't cover.

## Connection

| Action | Params | Result |
|--------|--------|--------|
| `version` | — | the API version (e.g. `6`). Use as a health check. |
| `sync` | — | triggers AnkiWeb sync. |

```bash
anki-connect version
# or raw:
curl -s localhost:8765 -X POST -d '{"action":"version","version":6}'
```

## Decks

| Action | Params | Result |
|--------|--------|--------|
| `deckNames` | — | list of deck names |
| `deckNamesAndIds` | — | `{name: id}` |
| `createDeck` | `{"deck": "A::B"}` | new deck id (no-op if it exists) |
| `changeDeck` | `{"cards": [id…], "deck": "X"}` | moves cards |
| `deleteDecks` | `{"decks": ["X"], "cardsToo": true}` | — |

## Note types (models)

| Action | Params | Result |
|--------|--------|--------|
| `modelNames` | — | list of note-type names |
| `modelFieldNames` | `{"modelName": "Basic"}` | field names for that model |

Built-in models used by `anki-add-notes`: `Basic` (Front, Back),
`Basic (and reversed card)` (Front, Back), `Cloze` (Text, Back Extra).

## Notes

| Action | Params | Result |
|--------|--------|--------|
| `addNote` | `{"note": <note>}` | new note id |
| `addNotes` | `{"notes": [<note>…]}` | list of ids (`null` per failed note) |
| `canAddNotes` | `{"notes": [<note>…]}` | list of booleans (false = duplicate/invalid) |
| `findNotes` | `{"query": "deck:X tag:y"}` | list of note ids |
| `notesInfo` | `{"notes": [id…]}` | fields, tags, model per note |
| `updateNoteFields` | `{"note": {"id": id, "fields": {…}}}` | — |
| `deleteNotes` | `{"notes": [id…]}` | — |
| `addTags` / `removeTags` | `{"notes": [id…], "tags": "a b"}` | — |

A **note** object:

```json
{
  "deckName": "Biology::Cell",
  "modelName": "Basic",
  "fields": { "Front": "…", "Back": "…" },
  "tags": ["bio", "exam1"],
  "options": { "allowDuplicate": false }
}
```

Example: add one note via the raw API —

```bash
curl -s localhost:8765 -X POST -d '{
  "action": "addNote", "version": 6,
  "params": { "note": {
    "deckName": "Spanish", "modelName": "Basic",
    "fields": {"Front": "perro", "Back": "dog"},
    "tags": ["vocab"], "options": {"allowDuplicate": false}
  }}
}'
```

## Media

| Action | Params | Result |
|--------|--------|--------|
| `storeMediaFile` | `{"filename": "x.png", "path": "/abs/x.png"}` or `{"filename","data": "<base64>"}` or `{"filename","url"}` | stored filename |
| `retrieveMediaFile` | `{"filename": "x.png"}` | base64 contents |
| `deleteMediaFile` | `{"filename": "x.png"}` | — |

Reference stored media in fields with `<img src="x.png">` or `[sound:x.mp3]`.

## GUI

| Action | Params | Result |
|--------|--------|--------|
| `guiBrowse` | `{"query": "deck:X"}` | opens the Browse window, returns matching card ids |
| `guiDeckOverview` | `{"name": "X"}` | opens a deck's overview |

## Error & duplicate handling

- A `null` entry in an `addNotes` result means that note failed (usually a
  duplicate). `anki-add-notes` pre-filters with `canAddNotes` and reports skips.
- To deliberately allow duplicates, set `options.allowDuplicate = true`
  (`anki-add-notes --allow-duplicate`).
- Anki search syntax (for `findNotes`/`guiBrowse`): `deck:Name`, `tag:x`,
  `"front:exact"`, `added:1`, `is:due`, combinable with spaces (AND) and `or`.

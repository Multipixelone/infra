---
name: anki-connect
description: Push high-quality flashcards (Basic and Cloze) directly into an already-running Anki via the AnkiConnect add-on (HTTP localhost:8765) — live insertion, no file to import. Use when the user wants cards added straight into Anki now, or wants to browse/find/update notes in a running Anki. To produce a portable .apkg file instead, use the anki skill.
tools: Bash, Read, Write, Edit, Grep, Glob
---

# Anki-Connect: push cards into a running Anki

Insert cards live into a running Anki using the AnkiConnect add-on, instead of
producing a `.apkg`. Cards use the **same `cards.json` schema** and the **same
card-writing methodology** as the `anki` skill — the only difference is the
backend.

## Prerequisite check (always first)

AnkiConnect requires Anki **desktop to be running** with the AnkiConnect add-on
installed (this repo installs it via `modules/productivity/anki.nix`). Probe it:

```
anki-connect version
```

If that errors (connection refused), tell the user to open Anki, and offer the
`anki` skill (`.apkg` export) as the offline alternative. Do not proceed until
the probe succeeds.

## Workflow

1. **Probe** with `anki-connect version`.
2. **Draft `cards.json`** following the methodology below. Schema:
   `../anki/reference/json-schema.md`. Full rulebook:
   `../anki/reference/card-writing.md` — **load it before drafting.**
3. **Self-review** every card against the checklist in `card-writing.md`.
4. **Show the drafted cards to the user for approval/edits** before inserting —
   live insertion writes directly into their collection.
5. **Insert:** `anki-add-notes cards.json`
   - creates the deck if needed, runs `canAddNotes` to skip duplicates, then
     `addNotes`. Add `--allow-duplicate` to force, `--dry-run` to preview the
     payload without touching Anki.
6. **Report** how many were added vs skipped.

## Methodology and card-type choice

Identical to the `anki` skill — do not re-derive it here. In brief:

- **Minimum information principle**: one atom per card; unambiguous cue → single
  answer; no dumps, lists, or enumerations; short both sides; stands alone.
- **Cloze** for facts-in-context (default for declarative facts); **Basic** for
  genuine Q→A; **Basic+Reversed** only when both directions are unambiguous.
- Cloze: 1–3 deletions, no giveaways (use `{{c1::answer::hint}}`), correct
  c-number grouping (same number = one card, different = separate cards).

The authoritative details, cloze deep-dive, bad→good gallery, and review
checklist are in **`../anki/reference/card-writing.md`**.

## Note-type mapping (to Anki's built-in models)

- `basic` → **Basic**
- `reversed` → **Basic (and reversed card)**
- `cloze` → **Cloze**

Anki's built-in *Basic* model has no Extra field, so `anki-add-notes` appends a
note's `extra` to the Back; cloze `extra` uses the native "Back Extra" field.

## Ad-hoc AnkiConnect calls

`anki-connect <action> '<json-params>'` runs any AnkiConnect action and prints
the JSON result — useful for browsing, searching, and editing:

```
anki-connect deckNames
anki-connect findNotes '{"query": "deck:Spanish tag:exam1"}'
anki-connect guiBrowse '{"query": "added:1"}'
```

See `reference/ankiconnect-api.md` for the actions and request shapes.

## The tool

`anki-tools` (this repo's Nix package, `pkgs/anki-tools/`) provides
`anki-add-notes` and `anki-connect`. Run via `nix run .#anki-tools` /
`nix shell .#anki-tools`, or directly once on PATH after `home-manager switch`.
No extra dependencies — the AnkiConnect path is pure stdlib.

---
name: anki
description: Create high-quality Anki flashcards (Basic flip cards and Cloze deletions) following evidence-based card-writing principles, and export a ready-to-import .apkg. Use whenever the user wants to make, generate, write, review, or edit Anki cards/decks/flashcards from notes, text, PDFs, or study material. For pushing cards into an already-running Anki instead of producing a file, use the anki-connect skill.
tools: Bash, Read, Write, Edit, Grep, Glob
---

# Anki: build .apkg decks

Turn study material into well-formed Anki cards and export a portable `.apkg`.
Cards are authored as a `cards.json` file and built with the Nix-packaged
`anki-build-deck` command.

## Workflow

1. **Gather & confirm.** Identify the source material and the deck name (use
   `::` for sub-decks, e.g. `Spanish::Verbs`). Ask only if genuinely unclear.
2. **Draft `cards.json`.** Write the cards following the methodology below. Read
   `reference/json-schema.md` for the exact format and `reference/card-writing.md`
   for the full rulebook.
3. **Self-review every card** against the checklist at the end of
   `reference/card-writing.md` — atomic, unambiguous, right card type, no
   lists/dumps. Fix before building.
4. **Build:** `nix run .#anki-tools -- cards.json out.apkg`
   (or `anki-build-deck cards.json out.apkg` once installed via home-manager;
   omit the output path to default to `<deck-name>.apkg`).
5. **Report** the card count and output path; offer to refine.

## The methodology (this is the point — make cards *well*)

Foundation: the **minimum information principle** — break material into the
smallest meaningful pieces and test one per card. Non-negotiables:

- **One atom per card** — a single fact, answerable in well under ~10 seconds.
- **Unambiguous cue → single answer.** If two answers are defensible, the cue is
  too vague; add context or split.
- **No verbatim dumps; no naked lists / sets / enumerations.** Reformulate.
- **Context-free but context-aware** — stands alone months later, yet carries
  enough lead-in (or a topic tag) to be unambiguous.
- **Keep both sides short.** A long answer is really several cards.

The full 20-rule rationale, a bad→good gallery, and the review checklist live in
`reference/card-writing.md`. **Load it before drafting.**

## Basic vs Cloze vs Basic+Reversed — choose deliberately

- **Cloze** when the fact is most natural *inside a sentence* and you're testing a
  specific term/number/name/date in situ, or a definition where the sentence is
  the cue. This is the default for declarative facts-in-context.
  `The capital of Australia is {{c1::Canberra}}.`
- **Basic** when there's a genuine question→answer with no useful sentence
  context, or a term→definition you only need in one direction.
- **Basic+Reversed** only when the association must be recalled **both**
  directions AND both are individually unambiguous (vocab↔meaning, symbol↔name).
  Never reverse one-to-many facts.

**Refuse/rewrite cloze anti-patterns:** over-clozing (keep 1–3 deletions);
grammatical/length giveaways (reword or add `{{c1::answer::hint}}`); unrelated
facts crammed into one card; clozing the only meaningful word.

Cloze c-numbers control cards: **same number reveals together on one card**,
**different numbers make separate cards**. Use overlapping clozes (different
numbers on one sentence) to replace enumerations. See the cloze deep-dive in
`reference/card-writing.md`.

## Round-trip editing of an existing deck

`anki-parse-deck deck.apkg > cards.json` → edit the JSON → rebuild with
`anki-build-deck`. Stable GUIDs mean re-importing the rebuilt deck updates the
same notes rather than duplicating them.

## Media

Reference images/audio by basename in the card HTML and list the files under the
note's `media` (paths relative to `cards.json`):
`{"type":"basic","front":"<img src=\"diagram.png\">","back":"…","media":["diagram.png"]}`.

## The tool

`anki-tools` (this repo's Nix package, `pkgs/anki-tools/`) provides:
`anki-build-deck` (cards.json → .apkg) and `anki-parse-deck` (.apkg → cards.json).
Run via `nix run .#anki-tools -- …`, `nix shell .#anki-tools`, or directly once
on PATH after `home-manager switch`.

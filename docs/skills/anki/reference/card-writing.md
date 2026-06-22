# Card-writing rulebook (canonical)

This is the single source of truth for *how* to write cards, shared by the
`anki` and `anki-connect` skills. Read it before drafting cards and run the
**self-review checklist** at the end before building/adding anything.

The foundation is the **minimum information principle**: the material you learn
should be broken into the smallest meaningful pieces, and each card should test
exactly one of them. Almost every rule below is a consequence of this idea.

---

## The 20 rules of formulating knowledge (condensed)

Adapted from Piotr Woźniak's *Twenty Rules of Formulating Knowledge*. Each is one
line; the ones that change card *structure* are expanded later.

1. **Understand before you memorize.** Never make cards from material you don't
   yet understand — disconnected facts are nearly impossible to retain.
2. **Learn before you memorize.** Build the big picture first; cards reinforce an
   existing scaffold, they don't build it.
3. **Build on the basics.** Don't skip "obvious" foundational cards; simple,
   well-understood items are the cheap glue that holds advanced knowledge.
4. **Minimum information principle.** Make items as simple as possible (but no
   simpler). Simple items are easy to schedule and recall reliably.
5. **Cloze deletion is easy and effective.** Fill-in-the-blank on a sentence is
   one of the highest-yield, lowest-effort formats — prefer it for facts in context.
6. **Use imagery.** A picture is worth a thousand words; add an image when it
   carries the meaning faster than text.
7. **Use mnemonic techniques** for arbitrary or interference-prone material.
8. **Graphic deletion** (image occlusion) is to images what cloze is to text.
9. **Avoid sets.** "Name all members of X" is brutal to recall; convert to
   meaningful, individually-cued facts.
10. **Avoid enumerations.** Ordered lists are nearly as bad as sets; use overlapping
    cloze or relationships instead of "list the steps".
11. **Combat interference.** Make similar-but-different items unmistakably distinct;
    ambiguity between cards is the #1 cause of lapses.
12. **Optimize wording.** Trim every word that isn't doing work; the cue should
    snap to a single answer.
13. **Refer to other memories** to anchor new items to ones you already hold.
14. **Personalize and use examples** — your own examples are far stickier.
15. **Rely on emotional states** when useful; vivid/affective cues recall better.
16. **Context cues simplify wording** — a topic tag or short lead-in beats a long,
    over-qualified question.
17. **Redundancy is not bad** in knowledge (as opposed to data); multiple angles on
    one fact strengthen it — but each angle is its *own* atomic card.
18. **Provide sources** so a card can be re-verified months later.
19. **Provide date stamping** for knowledge that changes over time.
20. **Prioritize.** Make cards for what matters; cutting low-value cards is itself a skill.

---

## The non-negotiables (apply to every card)

- **One atom per card.** A card tests a single fact answerable in well under ~10
  seconds. Two independent facts → two cards.
- **Unambiguous cue, single answer.** The front must admit exactly one correct
  response. If you can think of two defensible answers, the cue is too vague —
  add context or split it.
- **No verbatim dumps.** Never paste a paragraph onto one side. Reformulate into a
  precise question or a focused cloze.
- **No naked lists / sets / enumerations.** Don't make "list the 5 X" cards (see
  the worked example below).
- **Context-free but context-aware.** The card must stand alone months later — no
  "as mentioned above", no reference to the source document — yet carry enough
  lead-in (or a topic tag) to make the cue unambiguous.
- **Keep both sides short.** Long answers can't be graded honestly. If the answer
  is long, it's really several cards.

---

## Basic vs Cloze vs Basic+Reversed — the decision

Choose the type deliberately; the wrong type is the most common quality failure.

### Use **Cloze** when…
- The fact is most natural *inside a sentence / context*, and you want to test a
  specific term, number, name, or date *in situ*.
  - `The capital of Australia is {{c1::Canberra}}.`
- A **definition** where the surrounding sentence is the cue.
- You have **several related blanks** from one sentence that genuinely belong
  together (use `c1`, `c2`, … — see grouping below).
- Default to cloze for declarative facts-in-context; it's fast to write and study.

### Use **Basic** when…
- There's a genuine **question → answer** with no useful sentence context.
  - Front: `What enzyme unwinds DNA at the replication fork?` → Back: `Helicase`
- A **term ↔ definition** where you want clean recall in **one** direction only.
- Anything that reads awkwardly as a fill-in-the-blank, or where the blank would
  leave a giveaway.
- The answer needs explanation/working that doesn't fit a single deletion.

### Use **Basic + Reversed** when…
- The association must be recalled in **both** directions **and** both directions
  are individually unambiguous: vocabulary ↔ meaning, symbol ↔ name, term ↔
  one-line definition.
  - `perro` ↔ `dog` — fine to reverse.
- **Do not reverse one-to-many facts.** `dog → perro` is fine, but
  `mammal → dog` is not (many answers). If the reverse direction is ambiguous,
  use plain Basic.

### Cloze anti-patterns — refuse / rewrite these
- **Over-clozing**: so many deletions the sentence is unreadable or the remaining
  text gives no cue. Keep to **1–3 deletions** per card.
- **Giveaways**: grammatical agreement or blank length that betrays the answer
  (`an {{c1::}}…` hints a vowel; size of the blank hints word length). Reword, or
  add a hint to normalize: `{{c1::Canberra::city}}`.
- **Unrelated facts in one card**: clozing two facts that aren't really connected
  just to save a card. Split them.
- **Clozing the only meaningful word**, leaving a contentless stub
  (`{{c1::Photosynthesis}} is a process.` — no real cue). Make it a Basic Q or add
  real context.

---

## Cloze deep-dive

Cloze syntax: `{{c1::answer}}` or with a hint `{{c1::answer::hint}}`.

**Grouping with c-numbers** controls how many cards one note generates:
- **Same number** = revealed **together on one card**. Use when the blanks are a
  single unit you'd recall at once.
  - `Water is {{c1::two}} parts {{c1::hydrogen}}, one part {{c1::oxygen}}.`
    → one card hiding all three.
- **Different numbers** = **separate cards**, each hiding only its own blank
  (the others stay visible as context).
  - `{{c1::Newton}}'s {{c2::second}} law: F = ma.` → two cards.

**When to split into separate notes vs share one note**: if the blanks test
genuinely different facts, prefer different c-numbers (separate cards) or separate
notes so scheduling is independent. Share `c1` only for a tight unit.

**Overlapping clozes**: to test members of a group one-at-a-time while keeping the
rest as context, give each its own number on the *same* sentence. This is the
right replacement for an enumeration (see below).

**Hints** (`::hint`) normalize giveaways and disambiguate: use a category word, a
first letter, or a unit — never the answer itself.

---

## Bad → good gallery

**Enumeration → overlapping cloze (or atomic cards)**
- ❌ Front: `List the four chambers of the heart.` Back: `LA, RA, LV, RV`
- ✅ `The heart's upper chambers are the {{c1::atria}} and lower chambers the {{c2::ventricles}}.`
- ✅ (atomic) `What heart chamber pumps blood to the body?` → `Left ventricle`

**Paragraph dump → atomic cards**
- ❌ Front: `Explain the French Revolution.` Back: *(three sentences)*
- ✅ `The French Revolution began in {{c1::1789}}.`
- ✅ `What event on 14 July 1789 sparked the French Revolution?` → `The storming of the Bastille`

**Ambiguous cue → precise cue**
- ❌ `Einstein?` → `Relativity` (many possible answers)
- ✅ `Which physicist published the theory of general relativity (1915)?` → `Albert Einstein`

**Giveaway cloze → hinted cloze**
- ❌ `Mitochondria produce {{c1::ATP}} via aerobic respiration.` (fine) but
  `The powerhouse organelle is the {{c1::mitochondrion}}.` reversed cue is weak
- ✅ `The cell's main {{c1::ATP::molecule}}-producing organelle is the mitochondrion.`

**Two facts → two cards**
- ❌ `Paris is the capital of {{c1::France}}, whose currency is the {{c1::euro}}.`
- ✅ split: `Paris is the capital of {{c1::France}}.` and
  `The currency of France is the {{c1::euro}}.`

---

## Pre-build self-review checklist

Run this over **every** drafted card before building the deck or adding notes:

1. **Atomic?** One fact, one answer, ≤ ~10 s to recall. If not → split.
2. **Unambiguous?** Exactly one correct answer for the cue. If not → add context.
3. **Right type?** Cloze for facts-in-context, Basic for Q→A, Reversed only when
   both directions are unambiguous.
4. **Cloze sane?** 1–3 deletions, no giveaways, correct c-number grouping.
5. **No lists/sets/dumps?** Reformulated into atomic or overlapping-cloze cards.
6. **Stands alone?** No "see above"/source references; topic tag added if the cue
   needs a domain.
7. **Short answer?** If the back is long, it's multiple cards.
8. **Worth it?** Low-value trivia cut.

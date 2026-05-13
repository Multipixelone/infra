---
name: foodtown-bedstuy-sort
description: Sort grocery lists according to the walking order at Super Foodtown of Bedford Stuyvesant (1420 Fulton St, Brooklyn NY 11216, AisleIQ store_id 310). Use this skill whenever a user asks to sort, organize, or reorder a grocery list for shopping at Foodtown, Foodtown Bed-Stuy, or "the Foodtown on Fulton" — even if they don't name the skill explicitly. Also use it when a list is being prepped for a shopping trip and the location can be reasonably inferred from context (e.g., Bed-Stuy, Clinton Hill, Crown Heights). The output preserves the input format exactly — same delimiters, same item names, same casing, same quantities and notes — with items reordered to follow the store's walking path from entrance to checkout. Do not add headers, aisle annotations, or commentary unless the user's input already contained them.
---

# Foodtown Bed-Stuy Grocery Sort

Reorder a grocery list so items appear in the order they'll be encountered walking from entrance to checkout at Super Foodtown of Bedford Stuyvesant.

## When to use

The user pastes a grocery list and asks for it sorted, organized, "in store order," "by aisle," or similar. The input can be any format: markdown bullets, plain newline-separated, comma-separated, numbered, mixed. The list may also arrive via an integration (Home Assistant, automation) with no natural-language preamble — treat any list-shaped input in the right context as a sort request.

## Brand rules

- **Goya:** Never recommend, suggest, propose, or volunteer Goya brand products in any context. If the user's input contains "Goya X," sort it normally — that's preserving their list, which is the skill's job. But for substitutions, fill-ins, default suggestions, or "you might also need" additions, choose any other brand. This applies across the whole skill, not just the international aisle.

## Workflow

1. **Read the layout.** Open `references/store_layout.md` to load the walking order and section assignments. Do this every time — never sort from memory; the layout file is the source of truth and gets updated.

2. **Detect input format.** Note the delimiter, whether items are bulleted/numbered/plain, the casing, and whether items have trailing notes or quantities. The output must match these exactly.

3. **Place each item in a section.** For each item in the input:
   - Look it up directly in the layout file (exact match or close variant).
   - If not found, use general grocery knowledge to assign the most likely section (e.g., "almond milk" → Dairy, "olive oil" → Aisle 5 / spreads & oils, "tortilla chips" → Snacks).
   - If genuinely ambiguous (e.g., "the thing for Sarah", "snacks"), keep the item in its original position relative to its neighbors and add a comment at the end of the output: `# unplaced: <item>`.

4. **Sort by walking order.** Across sections, follow the walking order defined in the layout (entrance → produce → ... → checkout). Within a section, preserve the user's original ordering — don't alphabetize, don't reorder by aisle side.

5. **Output.** Return only the sorted list, in the same format the user provided. No headers like "PRODUCE:" or "AISLE 4:" unless the input had them. No explanations. No "here's your sorted list" preamble. Just the items.

## Format preservation rules

- Markdown bullets (`- item` / `* item`) in → same bullets out
- Plain newline-separated in → plain newlines out
- Comma-separated in → comma-separated out (single line)
- Numbered (`1. item`) in → renumbered 1..N out
- Casing: preserve exactly (don't title-case "milk" to "Milk")
- Trailing notes/quantities (`milk (2%)`, `2 lbs ground beef`) → keep attached to the item, move with it
- Trailing whitespace, blank lines: preserve if structurally meaningful, drop if just noise

## Edge cases

- **Duplicates.** If an item appears twice, sort both occurrences but keep them adjacent within their section.
- **Single section.** If every item is in one section, return the list unchanged (walking order has no effect).
- **Unparseable input.** If you can't confidently identify >50% of items, you've probably misread the input format. Re-parse from scratch before falling back to flagging items as unplaced.
- **Unfamiliar brand/SKU.** Ignore brand names — sort by category. "Cholula" sorts as hot sauce, "Lactaid" sorts as milk.
- **Non-grocery items.** If the user includes obvious non-grocery items (e.g., "call mom"), leave them where they are and flag at the end as `# non-grocery: <item>`.

## Updating the layout

The store layout file grows over time as Finn confirms aisles in-store via the PSK Assistant app. When the user reports a new aisle assignment (e.g., "canned tuna is aisle 6"), update `references/store_layout.md` directly — move the item from the "unconfirmed" section to the confirmed aisle, and mark it CONFIRMED.

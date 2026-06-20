---
name: choreops-ha-mcp
description: Manage entities, services, and dashboards for the ChoreOps custom integration (ccpk1/choreops) in Home Assistant. Use when tracking chores, assigning points, managing gamification badges, or troubleshooting routines.
---

# ChoreOps Skill for HA MCP

This skill provides the context and tooling map necessary to manage the [ChoreOps](https://github.com/ccpk1/choreops) custom integration via the [ha-mcp](https://github.com/homeassistant-ai/ha-mcp) server.

## Overview

ChoreOps is a sophisticated household task and routine manager. It manages:

- **Profiles**: Flexible roles for every approver and doer.
- **Chores**: Individual, shared, first-complete, and rotation models with advanced recurrence and overdue handling.
- **Points/XP & Rewards**: Custom currency and claim-and-approve redemption workflows.
- **Badges/Achievements**: Gamification progression with streaks and multipliers.

## State & Storage Model (read first)

- **Chores/rewards/points are storage-backed, _not_ declarative.** Runtime state lives in
  Home Assistant's `.storage/choreops` and is created/edited by calling `choreops.*`
  services — **not** by editing Nix. Changes apply live (no integration reload).
- **What _is_ in this repo:** `modules/iot/choreops.nix` seeds only the **7 telemetry-driven
  consumable chores** (3 shared vacuum-cleaning, 3 vacuum part-swaps as
  `rotation_primary_standby` with Finn primary, 1 Finn-only "Order Levoit Filter Sponges").
  It is a **one-time** seed script (`script.choreops_seed_consumable_chores`) — re-running
  creates duplicates. Every other chore (bathroom, kitchen rotations, cat, humidifier) was
  created at runtime and exists only in `.storage`.
- **Implication:** to change a runtime chore, call a service. Editing the Nix module only
  affects the consumable seed and only on a fresh re-seed. Don't expect repo edits to move
  existing chores.

### Entity-ID naming patterns

Construct ad-hoc reads/verification from these (dashboards must still use dynamic lookups —
see Dashboard rules — but for MCP inspection/edits these patterns are reliable):

- Per-user chore status: `sensor.<user>_choreops_chore_status_<chore_slug>`
- Points balance: `sensor.<user>_choreops_points` (rich `point_stat_*` attributes)
- Approve button: `button.<user>_choreops_approve_chore_<chore_slug>`
- `<user>` is lowercased first name (`finn`, `ciara`, `holland`); `<chore_slug>` is the
  snake*cased chore name. **Sweep trick:** a user assigned to every global chore (here
  **Finn**) — reading their `chore_status*\*` set covers all chores at once.
- **`completion_criteria` → sensor exposure:** `shared_first` exposes a
  `sensor.<instance>_choreops_<slug>_global_status`; `independent` and
  `rotation_*` expose **no** global-status sensor — read the `global_state` attribute on
  any assignee's per-user `chore_status` sensor instead. Useful per-chore attributes:
  `due_date`, `global_state`, `turn_user_name`, `completion_criteria`, `default_points`,
  `assigned_user_names`, `recurring_frequency`.

## Terminology Mapping

When querying configurations or building dashboards, be aware of the following terminology translations enforced by the integration:

- **Cumulative Badges** (Underlying HA configuration/docs) $\rightarrow$ **Ranks** (Kid/User facing UI).
- **Periodic Badges** (Underlying HA configuration/docs) $\rightarrow$ **Quests** (Kid/User facing UI).
- **OpsCenter** $\rightarrow$ The unified admin view for managing approvals, point adjustments, and overrides.
- **Rewards**: Must be created specifically as a `Reward` entity, not a `Chore`, to appear correctly in the Gamification dashboards.

## Chore Assignment & Scoring Rules

When creating, generating, or modifying chores, you must strictly adhere to the following point scale rules:

- **Default Baseline**: The default point value for any standard chore is **5 points**.
- **Difficulty Scaling**:
  - Assign **> 5 points** (e.g., 10, 15, or more) if the task is physically demanding, time-consuming, or particularly difficult (e.g., mowing the lawn, deep cleaning the garage).
  - Assign **< 5 points** (e.g., 1, 2, or 3) if the task is very easy, quick, or trivial (e.g., feeding the dog, making the bed).
- **Private-space exception (0 points by design):** a space owned by a single person is
  scored `independent`, single-assignee, and **0 points** _on purpose_. Here, the bathroom
  is Finn's alone — he deliberately earns nothing for those chores so he doesn't bank
  points the roommates have no way to earn. Do **not** raise these to the 5-point baseline
  or reassign them to a rotation; the 0 is intentional, not a misconfiguration.

## Household Context (this deployment)

- **Move-in is July 1, 2026** — the three roommates (Finn, Ciara, Holland) are not living
  there yet. Any new or reseeded chore's **first occurrence must fall after move-in**;
  never leave a chore due before July 1, 2026.
- **No points earned yet — zero balances are expected, not a fault.** Don't "fix" empty
  point/stat sensors.
- **Rewards & motivation are deferred** (the user will build them later). Do not create
  `Reward` entities, badges/ranks/quests, or motivational automations unless explicitly
  asked.
- **Per-person assignment policy** (intentional — don't "rebalance" or reassign):
  - **Finn** has **exclusive tasks** no one else is assigned: the entire **bathroom**
    (independent, single-assignee, 0-point — see exception above) and the **part-purchasing**
    chore "Order Levoit Filter Sponges" (the household doesn't want roommates buying parts).
    Finn is also in the shared/rotation pool.
  - **Ciara** shares **cat duty** with Finn and is in the shared/rotation pool.
  - **Holland** is intentionally **off cat duty** and is in the shared/rotation pool only.
  - **Cat tasks are Finn + Ciara only:** "Take out Cat Poop Bag & Reline" and "Fill Cat
    Water Bowl". Do not add Holland to these.
  - Everything else (kitchen, living room, deep-cleans, vacuum consumables) is a shared
    three-way rotation across Finn, Ciara, and Holland.

## Essential HA MCP Tools for ChoreOps

### 1. Discovering State

Use these tools to understand the current household setup before modifying anything:

- `ha_search_entities`: Search for entities under the `choreops` domain or by a specific profile/user name.
- `ha_get_state`: Inspect the current attributes of chore sensors, point balances, or badge progression (rich sensor data).
- `ha_get_overview`: Identify if multiple instances of ChoreOps are running.

### 2. Managing Operations (Services)

Use `ha_call_service` to trigger ChoreOps actions natively. Always verify exact parameters using `ha_list_services` for the `choreops` domain. Crucial known services include:

- **`choreops.set_rotation_turn`**: Forces the turn-holder for a rotation-based chore.
  - _Data_: `chore_id` (or `chore_name`) and `user_id` (or `user_name`).
- **`choreops.reset_rotation`**: Resets a rotation to the first assigned profile.
  - _Data_: `chore_id` (or `chore_name`).
- **`choreops.open_rotation_cycle`**: Temporarily allows any assigned profile to claim a rotation chore, regardless of whose turn it is.
  - _Data_: `chore_id` (or `chore_name`).
- **Lifecycle actions**: Automate `create`, `claim`, `approve`, `redeem`, and `adjust` operations via their respective `choreops.*` service calls.

**Scheduling / due-date family** (this is how you move first-occurrence dates, e.g. to keep
everything after a move-in date):

- **`choreops.set_chore_due_date`**: Set an explicit due date for one chore. **Omit
  `due_date` to _clear_ it** (chore goes dormant — correct for event-driven chores like
  "Fill Humidifier"). **Rejects dates in the past.** For `independent` chores, optional
  `user_name` targets one assignee. Best when you want a precise first date (e.g. anchor a
  batch to one day).
- **`choreops.reschedule_chores_after`**: Bulk-push chores so their next due date is after
  a boundary (`after`, required datetime). Non-obvious flags: `reschedule_independent`
  (default **true**), `reschedule_shared` (default **false** — must enable to touch
  shared/rotation chores), `reschedule_primary_standby` (default true),
  `allow_long_recurrences` (default **false** — monthly/quarterly/yearly are skipped unless
  enabled), `skip_non_recurring` (leave one-offs put instead of moving them to the
  boundary). Advances recurring chores to their _next natural occurrence_ after the
  boundary (not to the boundary itself).
- **`choreops.skip_chore_due_date`**: Skip the current occurrence; reschedule to the next
  per its recurrence. Optional `mark_as_missed`.
- **`choreops.reset_overdue_chores`**: Reset overdue chore(s) to pending and reschedule
  from recurrence + previous due date. Optional `chore_name` / `user_name` to scope.
- All scheduling services accept `config_entry_id` / `config_entry_title` for multi-instance
  setups.

### 3. Dashboard Integration Rules (Strict)

ChoreOps uses a dynamic, over-the-air dashboard generation system backed by the `ccpk1/choreops-dashboards` repository. If asked to modify or create Lovelace UI elements using MCP, adhere to these developer standards:

- **Dynamic Lookups**: _Never manually construct or hardcode entity IDs_. Always use dynamic lookup patterns for dashboard helper entities and related sensors. Lookups must be integration-instance aware.
- **Translations**: User-facing strings must use the translation sensor. Obtain user-facing text via `ui()` translation lookups rather than hardcoded text.

## Workflow Best Practices

1. **Live CRUD Updates**: Chore creation, edits, and deletions via services update runtime sensors and workflow buttons live _without_ needing an integration reload. You do not need to restart HA after making adjustments.
2. **Actionable Notifications**: Leverage HA notification services in combination with ChoreOps state attributes to build custom reminders (e.g., escalating alerts for overdue tasks, low-battery smart locks linked to tasks).
3. **Audit History**: Use `ha_get_history` or `ha_get_statistics` to track when chores were completed, claimed, or points were awarded over time.

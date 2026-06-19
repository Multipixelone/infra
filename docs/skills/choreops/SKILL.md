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

### 3. Dashboard Integration Rules (Strict)

ChoreOps uses a dynamic, over-the-air dashboard generation system backed by the `ccpk1/choreops-dashboards` repository. If asked to modify or create Lovelace UI elements using MCP, adhere to these developer standards:

- **Dynamic Lookups**: _Never manually construct or hardcode entity IDs_. Always use dynamic lookup patterns for dashboard helper entities and related sensors. Lookups must be integration-instance aware.
- **Translations**: User-facing strings must use the translation sensor. Obtain user-facing text via `ui()` translation lookups rather than hardcoded text.

## Workflow Best Practices

1. **Live CRUD Updates**: Chore creation, edits, and deletions via services update runtime sensors and workflow buttons live _without_ needing an integration reload. You do not need to restart HA after making adjustments.
2. **Actionable Notifications**: Leverage HA notification services in combination with ChoreOps state attributes to build custom reminders (e.g., escalating alerts for overdue tasks, low-battery smart locks linked to tasks).
3. **Audit History**: Use `ha_get_history` or `ha_get_statistics` to track when chores were completed, claimed, or points were awarded over time.

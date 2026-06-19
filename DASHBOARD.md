# Home Assistant dashboards — storage mode vs declarative (Nix/YAML)

How the household's HA dashboards are wired, **which of the two HA dashboard
modes each one uses**, and how to revise either by hand or with an AI. The one
rule that makes everything else make sense:

> **A dashboard is editable in exactly one place. Pick the wrong place and your
> change is either silently overwritten on the next rebuild, or silently lost on
> the next UI save.**

So before touching anything, identify the mode.

## The two modes (read this first)

Home Assistant Lovelace dashboards come in two mutually exclusive modes:

|                         | **Storage mode**                                                                    | **YAML mode (declarative)**                                                                       |
| ----------------------- | ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Source of truth         | HA's `.storage/lovelace*` (a DB-ish JSON blob)                                      | a `.yaml` file HA reads at startup                                                                |
| Edited via              | the **UI** (three-dot → Edit dashboard) or the ha-mcp `ha_config_*_dashboard` tools | edit the **file**, then reload                                                                    |
| Survives a Nix rebuild? | yes — Nix never touches `.storage`                                                  | the file is regenerated; **hand edits to the live config are wiped**                              |
| Survives a UI "Edit"?   | yes                                                                                 | **no — YAML-mode dashboards aren't editable in the UI at all** (the editor is read-only / hidden) |
| Our example             | `main-home` (the iPad kiosk)                                                        | `nixos-reorder` (the Reorder grid)                                                                |

The trap is that **both modes look identical in the sidebar and render the same
card types.** Nothing in the UI shouts "this one is declarative." You tell them
apart by where they're defined (see the table below), not by looking at them.

### Which of ours is which

| Dashboard       | Sidebar title | Mode           | Where it's defined                                           | Touch it how                                         |
| --------------- | ------------- | -------------- | ------------------------------------------------------------ | ---------------------------------------------------- |
| `main-home`     | **Main Home** | **storage**    | HA `.storage`, **not in this repo**                          | UI editor or ha-mcp; back up first                   |
| `nixos-reorder` | **Reorder**   | **YAML / Nix** | `modules/iot/roomieorder.nix`, generated from `catalog.json` | edit `catalog.json` (or the generator), then rebuild |

- **`main-home`** is the iPad wall kiosk. View 0 is the fridge dashboard. It is
  storage mode _on purpose_ — it's hand-tuned in the UI and we don't want Nix
  fighting the household's tweaks. It is **not** version-controlled here; the
  only backups are JSON exports in `~/ha-dashboard-backups/`. **Never** point a
  Nix `dashboards.*` block at it.
- **`nixos-reorder`** is the opposite philosophy: a single sidebar entry whose
  entire contents are derived from `catalog.json` and rebuilt on every
  `nixos-rebuild`. Editing it live is pointless — the next rebuild overwrites it.

---

# The Reorder dashboard (declarative — the Nix-managed one)

The "Reorder" sidebar entry is a one-view YAML-mode dashboard that shows one
tappable button per orderable staple. It is generated, end to end, from
`catalog.json`.

## Data flow (single source of truth)

```
catalog.json  (in inputs.secrets, shared with the link service)
      │
      ▼
inputs.roomieorder.lib.haButtons { catalogFile; endpoint; }   ← nix/ha-buttons.nix in the roomieorder flake
      │   emits: restCommand · scripts · sensors · dashboardCard · dashboardCardDynamic
      ▼
modules/iot/roomieorder.nix   ← wires those into the HA config + a YAML-mode dashboard
      │
      ▼
/nixos-reorder/reorder        ← the rendered grid (regenerated every rebuild)
```

`catalog.json` is the **only** file you edit to add/remove an item. It lives in
`inputs.secrets` (`${inputs.secrets}/roomieorder/catalog.json`) and is shared by
both hosts — the HA button generator on `iot` (`modules/iot/roomieorder.nix`)
and the buy service on `link` (`modules/link/roomieorder.nix`). Add a staple
there and its button, order script, and status sensor all appear on the next
rebuild. That catalog edit is the _only_ step.

## What `haButtons` emits

`inputs.roomieorder.lib.haButtons` (source: `nix/ha-buttons.nix` in the
`Multipixelone/roomieorder` flake) is a pure `catalog.json → HA fragments`
function. From one catalog it returns:

| Output                 | Goes into             | What it is                                                                                                                 |
| ---------------------- | --------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `restCommand`          | `config.rest_command` | the `POST /reorder` call to the link service                                                                               |
| `scripts`              | `iotHass.nixScripts`  | one `script.order_<key>` per item (this host routes Nix scripts through `iotHass.nixScripts`, a list — not `scriptsAttrs`) |
| `sensors`              | `config.rest`         | one `GET /items` poll → one `sensor.roomieorder_<key>` per item, carrying the `on_cooldown` attribute                      |
| `dashboardCard`        | a view's `cards`      | plain **core** `type: button` grid — the HACS-free fallback, no live state                                                 |
| `dashboardCardDynamic` | a view's `cards`      | the **Mushroom** grid we actually use (gray-out + "N ago") — needs HACS `mushroom`                                         |

`modules/iot/roomieorder.nix` feeds `dashboardCardDynamic` into a one-view
dashboard and registers it as a YAML-mode dashboard:

```nix
reorderDashboard = yamlFormat.generate "lovelace-reorder.yaml" {
  title = "Reorder";
  views = [ { title = "Reorder"; path = "reorder"; icon = "mdi:cart";
              cards = [ buttons.dashboardCardDynamic ]; } ];
};
# …
lovelace.dashboards.nixos-reorder = {
  mode = "yaml";
  filename = "${reorderDashboard}";   # the store path IS the .yaml file
  title = "Reorder"; icon = "mdi:cart"; show_in_sidebar = true;
};
systemd.services.home-assistant.reloadTriggers = [ reorderDashboard ];
```

A catalog change changes the derivation, which trips `reloadTriggers`, so the
dashboard reloads on rebuild with **no** manual ha-mcp push. The iPad kiosk
(`main-home`, storage mode) is left untouched.

## The card it generates (the validated card vocabulary)

Each item is **one** `custom:mushroom-template-card` (Mushroom, installed via
HACS). Shape (from `mushroomCardFor` in `nix/ha-buttons.nix`):

```yaml
type: custom:mushroom-template-card
primary: Dish Soap
icon: mdi:bottle-tonic
fill_container: true
# teal when orderable, grey ("disabled") while on cooldown
icon_color: >-
  {% if is_state_attr('sensor.roomieorder_dish_soap','on_cooldown',true)
  %}disabled{% else %}teal{% endif %}
# "3 days ago" only while on cooldown
secondary: >-
  {% set s = states('sensor.roomieorder_dish_soap') %}
  {% if is_state_attr('sensor.roomieorder_dish_soap','on_cooldown',true)
  and s not in ['unknown','unavailable',''] %}{{ relative_time(as_datetime(s)) }} ago{% endif %}
tap_action: { action: perform-action, perform_action: script.order_dish_soap }
```

The cards sit in a plain **`type: grid`** card (`columns: dashboardColumns`,
`square: false`). If any catalog item sets a `category`, the layout becomes a
`vertical-stack` of `## <Category>` markdown headings each followed by that
category's grid (empty-category items group under **"Other"**); otherwise it's a
single grid. Items sort alphabetically by button label within each group.

> Note: this is a plain `grid` card, **not** a sections-view subgrid. There's no
> `grid_options`/`column_span`/12-column-subgrid math here (that was the old
> storage-mode layout). Card count per row is the single `dashboardColumns` knob.

### The naming contract (don't break this)

For an item with key `dish_soap`, three things must line up — and the generator
keeps them aligned automatically, so you only break this if you hand-edit:

| Thing             | Value                                       | Created by               |
| ----------------- | ------------------------------------------- | ------------------------ |
| Status sensor     | `sensor.roomieorder_dish_soap`              | `rest:` poll of `/items` |
| Order script      | `script.order_dish_soap`                    | per-item HA script       |
| Card `tap_action` | `perform-action` → `script.order_dish_soap` | the card                 |

The card only ever fires the script; price/ASIN/cooldown all live server-side in
`catalog.json`, so a mistyped card can't order the wrong thing or skip a guard.

## Why Mushroom must be loaded (and how it is)

`dashboardCardDynamic` uses `custom:mushroom-template-card`, so the Mushroom
frontend JS must be served and registered as a Lovelace resource — even though
the _default_ dashboard stays storage mode. `modules/iot/roomieorder.nix` ships
it as a `customLovelaceModules` entry:

```nix
services.home-assistant.customLovelaceModules = [ pkgs.home-assistant-custom-lovelace-modules.mushroom ];
```

`modules/iot/homeassistant.nix` mirrors nixpkgs' behaviour: any
`customLovelaceModules` entry (a) is served at
`/local/nixos-lovelace-modules/mushroom.js`, (b) flips `lovelace.resource_mode`
to `"yaml"`, and (c) emits the `lovelace.resources` entry that actually loads the
JS. So the Mushroom cards render even though `main-home` is still storage mode.

## Knobs

Two things tune the generated grid, both passed through `catalog.json` /
`haButtons`:

- **`dashboardColumns`** (default `2`) — cards per row in the `grid` card.
- per-item **`category`** in `catalog.json` — groups cards under a `## <category>`
  heading. Omit it on every item and you get one flat grid.

Other `haButtons` args worth knowing: `pollSeconds` (status re-poll interval,
default 30 s), `statusSensorPrefix` (default `roomieorder_`), `defaultIcon`
(`mdi:cart` when an item has no `icon`), `endpoint` (the link intake URL).

## Gotchas (why it's built this way)

- **Use `mushroom-template-card`, not `conditional` cards with `condition:
template`.** HA's card editor flags template conditions as **"Conditions are
  invalid"** and renders them as red error blocks. The single Mushroom card does
  gray-out + timestamp via Jinja _inside_ the card (`icon_color`/`secondary`),
  which HA evaluates freely — no `conditional` swap, no rejected conditions.
- **`perform-action`, not `call-service`.** HA 2024.8+ renamed it; the key is
  `perform_action` (underscore) inside `tap_action`.
- **Cooldown is enforced server-side**, not by the dashboard. The gray-out is
  purely visual — tapping a greyed item still calls the script, but the
  roomieorder service rejects it (HTTP 200, no double order). Worst case of a
  stale `on_cooldown` attribute is a harmless tap.
- **`unknown` sensor state** = never ordered (no `last_placed_at`). The
  `secondary` template guards `unknown`/`unavailable`/`''` so `as_datetime()`
  never errors.
- **Bad MDI icon name = blank card / "missing render."** An icon that doesn't
  exist renders as nothing. Verify before using — quickest check is whether the
  SVG exists:
  `curl -so /dev/null -w "%{http_code}" https://raw.githubusercontent.com/Templarian/MaterialDesign-SVG/master/svg/<name>.svg`
  (`200` = valid, `404` = doesn't exist), or search pictogrammers.com.

## Adding / removing / restyling an item

1. **Add/remove a staple:** edit `catalog.json` (in `inputs.secrets`). Add the
   key with its `title`, optional `button`/`icon`/`category`. The script,
   sensor, and card all follow on the next rebuild.
2. **Restyle the whole grid:** change `dashboardColumns`, add `category` fields,
   or (for a structural change) edit `nix/ha-buttons.nix` upstream.
3. **Deploy:** `just colmena-apply-tag iot`. `reloadTriggers` reloads HA.
4. **Never** edit the live `/nixos-reorder/reorder` view in the UI — it's YAML
   mode, so the editor won't save, and a rebuild would overwrite it anyway.

---

# Editing the storage-mode kiosk (`main-home`)

Different rules entirely, because there's no Nix source — `.storage` _is_ the
source of truth.

- **Back up first.** Export the dashboard JSON to `~/ha-dashboard-backups/`
  before any non-trivial change (that's the only version history this dashboard
  has).
- **Via the UI:** open the dashboard, three-dot → Edit dashboard.
- **Programmatically (ha-mcp):** it's storage mode, so use
  `ha_config_set_dashboard` with a `python_transform`. Always pass the current
  `config_hash` from `ha_config_get_dashboard` for optimistic locking; it
  changes after every write. Sandbox limits: no `import`, no
  f-strings/`.format()`, no `.replace()` — build strings with `+` concatenation.
- **Don't try to "Nix-ify" it by pointing a `lovelace.dashboards.*` block at it.**
  That would put it in YAML mode and make the household's UI edits impossible.
  If you ever _do_ want it declarative, that's a migration (export → translate to
  YAML → switch mode), not a config tweak. See **Migrating `main-home` to Nix**
  below.

---

# Installed custom cards (the design palette)

These are the HACS frontend modules installed on this HA. **Verify the live
list** before relying on it: `ha_get_hacs_info(action="search",
installed_only=True, category="lovelace")`.

> ⚠️ **Most of these don't actually load right now.** See **The resource-mode
> breakage** below. Only Mushroom renders today because it's the one module Nix
> declares. The "Loads now?" column reflects reality on HA 2026.6.3, verified on
> the box — not what's installed.

| Card                                               | What it's for                                                     | In nixpkgs?                 | Loads now?  | Used on live `main_home` |
| -------------------------------------------------- | ----------------------------------------------------------------- | --------------------------- | ----------- | ------------------------ |
| **Mushroom** (`custom:mushroom-*`)                 | the workhorse — clean tiles/chips/template cards; the house look  | ✅ `mushroom`               | ✅ (Nix)    | yes (42+ cards)          |
| **card-mod**                                       | CSS into (almost) any card — rounding, colors, fonts, hiding bits | ✅ `card-mod`               | ❌ orphaned | yes (styling)            |
| **auto-entities**                                  | auto-populate a card's entity list from a filter                  | ✅ `auto-entities`          | ❌ orphaned | yes                      |
| **mini-graph-card**                                | minimalist history graphs/sparklines                              | ✅ `mini-graph-card`        | ❌ orphaned | yes                      |
| **Clock Weather Card**                             | iOS-style date/time + multi-day forecast                          | ✅ `clock-weather-card`     | ❌ orphaned | (recently)               |
| **Atomic Calendar Revive**                         | advanced calendar/agenda card                                     | ✅ `atomic-calendar-revive` | ❌ orphaned | yes                      |
| **Today Card**                                     | today's calendar schedule                                         | ❌ **not packaged**         | ❌ orphaned | yes (4 cards)            |
| Kiosk Mode                                         | hides header/sidebar for wall tablets                             | ✅ `kiosk-mode`             | ❌ orphaned | kiosk chrome             |
| Calendar Card Pro / Week / Daylight / Week-planner | various calendar layouts                                          | ❌ not packaged             | ❌ orphaned | no (dropped)             |

So of the cards the live kiosk **uses**, everything except **Today Card** is
already in nixpkgs — making them load is mostly wiring (see the plan below).

**Reach-for guide** (once they load): Mushroom for almost everything; `card-mod`
when Mushroom's options run out (it's a styling layer, not a card);
`auto-entities` to avoid hand-listing entities; `mini-graph-card` for trends; a
calendar card for agenda views. Don't emit a `custom:` card whose module isn't
**declared in Nix** — it renders as **"Custom element doesn't exist."**

---

# Design best practices (making it look nice)

Grounded in the current HA community consensus (sources at the bottom). These are
the rules to bake into any dashboard work here.

**Layout**

- **Prefer the Sections view** (`type: sections`) over masonry/stacks. It's a
  responsive grid: it re-flows columns to the screen width while keeping each
  section's internal column count fixed, so card positions (muscle memory) stay
  put across phone/tablet/kiosk. This is what `main-home` already uses.
- **Group, don't sprawl.** Group related controls into one section with a
  heading rather than scattering individual entity cards. A `heading` card per
  section beats a wall of titled tiles.
- **Keep the main view scannable** — aim for well under ~50 entities on the
  primary view. Push detail onto secondary views or popups.
- **Regular grid rhythm.** Let cards span whole grid columns/rows; consistent
  card sizes read as "tidy." Section gap is the `--grid-gap` CSS var (default
  32px) — tighten it via theme/`card-mod` for a denser kiosk.

**Visual**

- **"Answer questions before they're asked."** The card should surface the answer
  ("how warm is it", "is the door locked") without a tap. Favor state-colored
  icons (like the Reorder grid's teal/disabled) over raw text.
- **One accent, restrained color.** Use color to mean something (on/off,
  warn/ok), not for decoration. Mushroom's `icon_color` + a theme gives a
  coherent palette for free.
- **Mushroom + a theme + `card-mod`** is the house recipe for a polished look:
  Mushroom for the card shapes, a dark theme for the kiosk, `card-mod` for the
  last 10% (corner radius, hiding chevrons, conditional row coloring). ⚠️
  `card-mod` is one of the **currently-orphaned** modules — its styling is
  silently ignored until it's Nix-declared (see **The resource-mode breakage**).
- **Whitespace is a feature.** Don't fill every cell; breathing room reads as
  "designed."

**Behavior**

- **Conditional / template visibility** to hide irrelevant cards (the fridge
  card already does this via its `valid_until` gate) — but remember the Reorder
  gotcha: do conditionality _inside_ a Mushroom template card's Jinja, not via
  `conditional` cards with `condition: template`, which HA's editor rejects.
- **`tap`/`hold`/`double_tap` actions** give one tile multiple jobs (tap =
  toggle, hold = more-info) and cut card count.

---

# The resource-mode breakage (verified — fix this first)

**Right now, every HACS frontend card except Mushroom is broken**, and has been
since Mushroom was wired into Nix. Verified on `colmena.iot`, HA 2026.6.3:

- `configuration.yaml` (the nix-store one) sets `lovelace.resource_mode: yaml`
  with a single resource: `/local/nixos-lovelace-modules/mushroom.js`. That entry
  is emitted by `customLovelaceModules` in `modules/iot/homeassistant.nix`.
- **HA's resource loading is exclusive: YAML resources _or_ the storage
  collection, never both.** Defining any YAML `lovelace.resources` (which the
  Mushroom wiring does) flips the whole instance to YAML mode and orphans HACS's
  `.storage/lovelace_resources` collection — which still lists all ~12 plugins at
  `/hacsfiles/...`, now dead.
- The served index injects only HACS's `iconset.js` as an `extra_module_url`, not
  the plugin cards — so there's no second load path saving them.
- Net: the live `main_home` references `card-mod`, `auto-entities`,
  `mini-graph-card`, `clock-weather-card`, `atomic-calendar-revive`, and
  `today-card`, and **all of them render as "Custom element doesn't exist."**
  Only the 50+ Mushroom cards work.

**Verify any time** with `ha_config_list_dashboard_resources()` — if it returns
only the Nix mushroom entry, everything else is orphaned.

---

# The fix / goal: all custom modules declared in Nix (single source of truth)

Since we're already in YAML resource mode, the path _forward_ (not back to HACS)
is to declare **every** frontend module in Nix so they all land in the YAML
`resources` list and load. This both fixes the breakage and makes the repo the
single source of truth for dashboard resources — no HACS deviation.

This is **independent of, and a prerequisite for, migrating the dashboard config
itself** (next section). Fixing resources does _not_ require touching `main_home`'s
storage-mode layout — the existing cards start rendering as soon as their modules
load.

### Step 1 — declare the modules (the real fix)

Add every used module to `services.home-assistant.customLovelaceModules` in
`modules/iot/roomieorder.nix` (or a dedicated `modules/iot/lovelace-modules.nix`).
nixpkgs status of the cards `main_home` actually uses, verified:

| Module                         | nixpkgs `home-assistant-custom-lovelace-modules.*` |
| ------------------------------ | -------------------------------------------------- |
| `mushroom`                     | ✅ (already wired)                                 |
| `card-mod`                     | ✅                                                 |
| `auto-entities`                | ✅                                                 |
| `mini-graph-card`              | ✅                                                 |
| `clock-weather-card`           | ✅                                                 |
| `atomic-calendar-revive`       | ✅                                                 |
| `today-card` (`ha-today-card`) | ❌ **not packaged**                                |

So six are one-liners; **only `today-card` needs work** — either a small
`fetchzip`/`fetchFromGitHub` derivation (mirror the HACS derivation pattern in
`modules/iot/homeassistant.nix`, which builds the `hacs` component itself), or
swap those 4 `today-card` instances for a packaged calendar card. Sketch:

```nix
services.home-assistant.customLovelaceModules = with pkgs.home-assistant-custom-lovelace-modules; [
  mushroom card-mod auto-entities mini-graph-card clock-weather-card atomic-calendar-revive
  # + today-card  (custom derivation, see above)
];
```

The existing `customLovelaceModules → lovelace.resources` merge in
`homeassistant.nix` then emits one YAML resource per module, and the orphaned
cards render. **`card-mod` must be in the list** or every `card_mod:` style block
is silently ignored.

### Step 2 — retire HACS's resource role

Once all modules are Nix-declared, HACS is no longer the source of truth for
frontend resources (it never effectively was, post-breakage). Options, in order of
"single source of truth without deviation":

- **Keep HACS for discovery only**, manage all _resources_ via Nix (current
  direction — lowest risk). The stale `.storage/lovelace_resources` entries are
  inert in YAML mode; optionally prune them so the two don't look like they
  disagree.
- **Drop HACS frontend modules entirely** and pin each card's version in Nix
  (fully declarative, reproducible builds, no HACS update prompts). HACS the
  _integration_ (custom_components) can stay for any non-frontend repos.

Pin versions in the derivations either way, so a card update is a reviewed Nix
bump, not a surprise.

---

# Migrating the `main_home` dashboard config to Nix (the larger goal)

With resources fixed (above), the dashboard _layout_ can also move from storage
mode to a Nix-generated YAML dashboard — the full single-source-of-truth end state.

1. **Export** the live `main_home` JSON (start from `~/ha-dashboard-backups/`;
   the live one is newer — pull it via the ha-mcp dashboard tools or off the box).
2. **Translate** to a `sections`-view YAML structure and generate it with
   `pkgs.formats.yaml`, exactly like `reorderDashboard` in
   `modules/iot/roomieorder.nix`.
3. **Register** it as a YAML dashboard (`lovelace.dashboards.nixos-home = { mode
= "yaml"; filename = ...; }`) and add it to `reloadTriggers`. Decide whether it
   _replaces_ storage `main-home` (repoint the kiosk URL) or coexists during cutover.
4. **Trade-off:** once YAML-managed, the household can't tweak it from the UI —
   every change is a repo edit + `just colmena-apply-tag iot`. That's the point
   (version control, reproducibility), but it's a real change for a shared wall
   tablet. Migrate the stable parts; leave genuinely fiddly bits in storage if needed.

**Back up first**, always: export `main_home` JSON to `~/ha-dashboard-backups/`
before cutover so you can restore the storage version.

---

# Asking an AI to generate or revise a dashboard

This repo is set up so an AI can do dashboard work safely. Give it these
guardrails in the prompt and the output will land first try:

1. **State the target and its mode up front.** "Revise the YAML/Nix-generated
   `nixos-reorder` dashboard" vs "revise the storage-mode `main-home` kiosk" lead
   to completely different workflows (edit `catalog.json` + rebuild, vs ha-mcp
   `python_transform` + `config_hash`). The #1 failure is an AI hand-editing a
   YAML-mode dashboard live (silently overwritten) or trying to `python_transform`
   a Nix-generated one.
2. **Point it at the real source.** For Reorder, that's `catalog.json` and
   `modules/iot/roomieorder.nix` (+ `nix/ha-buttons.nix` upstream) — not the
   rendered view. For the kiosk, that's `.storage` via ha-mcp, with a backup to
   `~/ha-dashboard-backups/` first.
3. **Constrain the card vocabulary to what's installed.** Point it at the
   **Installed custom cards** table above. Core cards (`button`, `markdown`,
   `grid`, `vertical-stack`, `entities`, `sections`, `heading`, `tile`, `gauge`)
   are always safe; `mushroom-*`, `card-mod`, `auto-entities`, `mini-graph-card`,
   `clock-weather-card`, `calendar-card-pro` are installed. Anything else needs a
   resource loaded first — for the Nix-managed dashboard that's a new
   `customLovelaceModules` entry. Tell it **not** to invent `custom:` cards.
4. **Aim it at the design rules** in **Design best practices**: Sections view,
   group under headings, state-colored icons over text, Mushroom + theme +
   `card-mod`, keep the main view under ~50 entities. "Make it look nice" lands
   far better when the AI has these constraints than left open.
5. **Bake in the gotchas:** `perform-action`/`perform_action` (not
   `call-service`); no `conditional` + `condition: template` (use Jinja inside a
   template card); validate every `mdi:` icon against the MaterialDesign-SVG repo;
   guard `unknown`/`unavailable`/`''` before `as_datetime()`.
6. **Tell it where state comes from.** Item liveness is
   `sensor.roomieorder_<key>` + its `on_cooldown` attribute; ordering is
   `script.order_<key>`; cooldown/price/ASIN are server-side in `catalog.json`.
   The card never decides anything — it reads the sensor and fires the script.
7. **Have it verify against live HA, then write Nix.** Per `AGENTS.md`: use the
   ha-mcp `ha_*` tools to read entity state and dry-run service calls, but
   **author the change as Nix** (`catalog.json` / `iotHass.*` /
   `services.home-assistant.config.*`) — never `ha_config_set_yaml` /
   `ha_write_file`, which drift from Nix. Deploy with
   `just colmena-apply-tag iot`.

Minimal prompt skeleton that works:

> "Revise the **Reorder** dashboard (YAML mode, generated by
> `modules/iot/roomieorder.nix` from `catalog.json`). I want `<change>`. Use
> Mushroom template cards in a grid, keep the `roomieorder_<key>` /
> `order_<key>` naming contract, validate icons, and show me the `catalog.json`
> (or generator) diff plus the rebuild command — don't edit the live dashboard."

---

# Sources (design best practices)

- [HA: A Home-Approved Dashboard — Sections view & grid system](https://www.home-assistant.io/blog/2024/03/04/dashboard-chapter-1/)
- [HA docs: Sections view](https://www.home-assistant.io/dashboards/sections/)
- [HA Community: Mushroom Cards + card-mod styling guide](https://community.home-assistant.io/t/mushroom-cards-card-mod-styling-config-guide/600472)
- [piitaya/lovelace-mushroom (Mushroom + themes)](https://github.com/piitaya/lovelace-mushroom)
- [ANTLATT: HA Dashboard Setup — the complete 2026 guide](https://www.antlatt.com/blog/home-assistant-dashboard-guide/)
- [HomeShift: 25 HA dashboard examples that actually look good (2026)](https://joinhomeshift.com/home-assistant-dashboard-examples)
- [HA Community: customize the `--grid-gap` between sections](https://community.home-assistant.io/t/customize-gap-between-new-sections-dashboard-layout/701480)

#!/usr/bin/env python3
"""Write 0-3 nudge lines to sensor.fridge_nudges for the kitchen-iPad fridge dashboard.

Reads household state from HA's REST API (todos, calendars, weather, presence).
Python deterministically picks at most one chore (CHORE_WEIGHTS table breaks
ties: weight asc, due-today first, oldest-due first, alphabetic) plus any
firing cross-cutting cues (umbrella / foodtown / theatre / layers). The LLM
only rephrases the picked chore summary into a Title-Case sticky-note
imperative — cross-cutting cues are fixed strings and never see the LLM.
If no chore qualifies, the LLM is not called at all.

The result is POSTed to sensor.fridge_nudges with state = first line,
attributes = {lines, valid_until}.

On any failure (HA error, OpenAI exception, JSON parse error, schema mismatch)
the script exits non-zero BEFORE posting, leaving the previous good state
intact. Once that state's valid_until elapses the dashboard card silently
disappears.

Environment:
    HA_URL              default http://localhost:8123
    HA_TOKEN_FILE       path to file containing a long-lived HA token
    NUDGE_SKILL_DIR     directory containing SKILL.md
    NUDGE_MODEL         OpenAI model, default gpt-5-nano
    NUDGE_VALID_MINUTES validity window before card auto-hides, default 30
    OPENAI_API_KEY      used by the openai client
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta
from pathlib import Path

from openai import OpenAI

HA_URL = os.environ.get("HA_URL", "http://localhost:8123").rstrip("/")
SKILL_DIR = Path(os.environ["NUDGE_SKILL_DIR"])
MODEL = os.environ.get("NUDGE_MODEL", "gpt-5-nano")
VALID_MINUTES = int(os.environ.get("NUDGE_VALID_MINUTES", "30"))
HA_TOKEN = Path(os.environ["HA_TOKEN_FILE"]).read_text().strip()

SENSOR_ENTITY = "sensor.fridge_nudges"
CHORES_TODO = "todo.chores"
FOODTOWN_TODO = "todo.foodtown"
CALENDARS = {
    "finn": "calendar.finn",
    "ciara": "calendar.ciara",
    "theatre": "calendar.theatre_2",
    "holidays": "calendar.holidays_in_united_states",
}
WEATHER_ENTITY = "weather.openweathermap"
RAIN_SENSOR = "sensor.openweathermap_peak_rain_chance_12h"
TEMP_SENSOR = "sensor.openweathermap_temperature"
CONDITION_SENSOR = "sensor.openweathermap_condition"
PERSONS = ["person.finn", "person.ciara", "person.emily"]
SUN_SENSOR = "sensor.sun_next_setting"

# Edit me to nudge which chore the dashboard surfaces first. Lower = preferred.
# Keys are exact-match (case-insensitive) against todo.chores summaries.
# Anything not listed defaults to CHORE_DEFAULT_WEIGHT — add an entry if a
# chore needs tuning.
CHORE_WEIGHTS = {
    "refill med case": 1,
    "clip fingernails": 1,
    "fill ice maker": 1,
    "change hand towel": 1,
    "refill soap": 1,
    "take out trash": 2,
    "take out recycling": 2,
    "clip toenails": 2,
    "open new contact": 2,
    "toss expired food in fridge": 3,
    "water plants": 3,
    "add coned to hass": 4,
    "clean washer tub": 5,
}
CHORE_DEFAULT_WEIGHT = 3


def ha_request(method: str, path: str, payload: dict | None = None) -> dict:
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        f"{HA_URL}{path}",
        method=method,
        data=data,
        headers={
            "Authorization": f"Bearer {HA_TOKEN}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read()
        return json.loads(body) if body else {}


def get_state(entity_id: str) -> dict:
    try:
        return ha_request("GET", f"/api/states/{entity_id}")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return {}
        raise


def parse_date(s: str | None) -> date | None:
    if not s:
        return None
    try:
        if "T" in s or " " in s:
            return datetime.fromisoformat(s.replace("T", " ").rstrip("Z")).date()
        return date.fromisoformat(s)
    except (TypeError, ValueError):
        return None


def parse_dt(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("T", " ").rstrip("Z"))
    except (TypeError, ValueError):
        return None


def minutes_until(start_time_str: str | None, now: datetime) -> int | None:
    dt = parse_dt(start_time_str)
    if dt is None:
        return None
    return int((dt - now).total_seconds() / 60)


def get_todo_items(entity_id: str) -> list[dict]:
    try:
        resp = ha_request(
            "POST",
            "/api/services/todo/get_items?return_response",
            {"entity_id": entity_id},
        )
        return resp["service_response"][entity_id]["items"]
    except (KeyError, urllib.error.HTTPError):
        return []


def slim_forecast(forecast: list[dict]) -> list[dict]:
    out: list[dict] = []
    for entry in forecast[:3]:
        out.append(
            {
                "datetime": entry.get("datetime"),
                "temperature": entry.get("temperature"),
                "condition": entry.get("condition"),
                "precipitation_probability": entry.get("precipitation_probability"),
            }
        )
    return out


def gather_facts() -> dict:
    today = date.today()
    now = datetime.now()

    raw_chores = [
        i for i in get_todo_items(CHORES_TODO) if i.get("status") == "needs_action"
    ]
    overdue: list[dict] = []
    due_today: list[dict] = []
    for item in raw_chores:
        d = parse_date(item.get("due"))
        if d is None:
            continue
        if d < today:
            overdue.append({"summary": item.get("summary"), "due": item.get("due")})
        elif d == today:
            due_today.append({"summary": item.get("summary"), "due": item.get("due")})

    foodtown_state = get_state(FOODTOWN_TODO).get("state")
    foodtown_count = (
        int(foodtown_state) if foodtown_state and foodtown_state.isdigit() else 0
    )

    calendars: dict[str, dict | None] = {}
    for key, entity in CALENDARS.items():
        s = get_state(entity)
        if not s:
            calendars[key] = None
            continue
        attrs = s.get("attributes") or {}
        start = attrs.get("start_time")
        start_date = parse_date(start)
        starts_today = start_date == today if start_date else None
        if key == "holidays":
            calendars[key] = {"state": s.get("state"), "starts_today": starts_today}
            continue
        mins = minutes_until(start, now)
        if mins is None or mins > 1440:
            calendars[key] = None
            continue
        calendars[key] = {
            "state": s.get("state"),
            "message": attrs.get("message"),
            "start_time": start,
            "end_time": attrs.get("end_time"),
            "all_day": attrs.get("all_day"),
            "minutes_until_start": mins,
            "starts_today": starts_today,
        }

    weather_state = get_state(WEATHER_ENTITY)
    forecast = (weather_state.get("attributes") or {}).get("forecast") or []

    facts = {
        "now": now.isoformat(timespec="minutes"),
        "today": today.isoformat(),
        "weekday": today.strftime("%A"),
        "overdue": overdue,
        "due_today": due_today,
        "chores_pending_count": len(raw_chores),
        "foodtown_count": foodtown_count,
        "calendars": calendars,
        "weather": {
            "temp_f": get_state(TEMP_SENSOR).get("state"),
            "condition": get_state(CONDITION_SENSOR).get("state"),
            "peak_rain_chance_12h": get_state(RAIN_SENSOR).get("state"),
            "forecast_next": slim_forecast(forecast),
        },
        "persons": {p: get_state(p).get("state") for p in PERSONS},
        "sunset": get_state(SUN_SENSOR).get("state"),
    }
    return facts


def chore_weight(summary: str) -> int:
    return CHORE_WEIGHTS.get(summary.strip().lower(), CHORE_DEFAULT_WEIGHT)


def select_candidates(facts: dict) -> dict:
    # Tag each item with is_today so we can prefer due-today over older
    # overdue at the same weight. 0-before-1 in the key = today wins.
    pool = [(i, False) for i in facts["overdue"]] + [
        (i, True) for i in facts["due_today"]
    ]
    pool.sort(
        key=lambda x: (
            chore_weight(x[0].get("summary") or ""),
            0 if x[1] else 1,
            x[0].get("due") or "9999-99-99",
            x[0].get("summary") or "",
        )
    )
    chore_summary = pool[0][0]["summary"] if pool else None

    cals = facts["calendars"]
    any_today = any((c or {}).get("starts_today") for c in cals.values())
    try:
        rain = float(facts["weather"].get("peak_rain_chance_12h") or 0)
    except (TypeError, ValueError):
        rain = 0
    try:
        temp = float(facts["weather"].get("temp_f") or 999)
    except (TypeError, ValueError):
        temp = 999
    evening_event = any(
        (c or {}).get("starts_today")
        and ((c or {}).get("start_time") or "")[11:13].isdigit()
        and int(((c or {}).get("start_time") or "")[11:13]) >= 17
        for c in cals.values()
    )

    return {
        "chore_summary": chore_summary,
        "umbrella": rain >= 50 and any_today,
        "foodtown": facts["foodtown_count"] >= 5,
        "theatre_tonight": bool((cals.get("theatre") or {}).get("starts_today")),
        "layers_tonight": temp < 45 and evening_event,
    }


def phrase_chore(summary: str) -> str:
    system = (SKILL_DIR / "SKILL.md").read_text()
    client = OpenAI(timeout=30.0)
    resp = client.chat.completions.create(
        model=MODEL,
        response_format={
            "type": "json_schema",
            "json_schema": {
                "name": "nudge_line",
                "strict": True,
                "schema": {
                    "type": "object",
                    "additionalProperties": False,
                    "required": ["line"],
                    "properties": {
                        "line": {"type": "string", "maxLength": 60},
                    },
                },
            },
        },
        reasoning_effort="low",
        max_completion_tokens=1500,
        seed=42,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": summary},
        ],
    )
    text = resp.choices[0].message.content or "{}"
    obj = json.loads(text)
    line = obj.get("line")
    if not isinstance(line, str):
        raise ValueError(f"non-string line field: {text!r}")
    return line.strip()


def assemble_lines(picks: dict, chore_line: str | None) -> list[str]:
    lines: list[str] = []
    if chore_line:
        lines.append(chore_line)
    if picks["umbrella"]:
        lines.append("Bring Umbrella")
    if picks["foodtown"]:
        lines.append("Foodtown Run")
    if picks["theatre_tonight"]:
        lines.append("Theatre Tonight")
    if picks["layers_tonight"]:
        lines.append("Bring Layers Tonight")
    return lines[:3]


def post_sensor(lines: list[str], valid_minutes: int) -> None:
    # tz-aware so HA's `as_datetime` filter produces a tz-aware result and
    # the dashboard's `> now()` comparison doesn't raise on naive/aware mix.
    valid_until = (
        datetime.now().astimezone() + timedelta(minutes=valid_minutes)
    ).isoformat(timespec="seconds")
    payload = {
        "state": lines[0] if lines else "",
        "attributes": {
            "lines": lines,
            "valid_until": valid_until,
        },
    }
    ha_request("POST", f"/api/states/{SENSOR_ENTITY}", payload)


def main() -> int:
    try:
        facts = gather_facts()
    except Exception as e:
        print(f"nudge-writer: gather_facts failed: {e}", file=sys.stderr)
        return 1

    picks = select_candidates(facts)

    chore_line: str | None = None
    if picks["chore_summary"]:
        try:
            chore_line = phrase_chore(picks["chore_summary"])
        except Exception as e:
            print(f"nudge-writer: phrase_chore failed: {e}", file=sys.stderr)
            return 1

    lines = assemble_lines(picks, chore_line)

    try:
        post_sensor(lines, VALID_MINUTES)
    except Exception as e:
        print(f"nudge-writer: HA POST failed: {e}", file=sys.stderr)
        return 1

    joined = " | ".join(lines) if lines else "(empty)"
    print(f"nudge-writer: posted: {joined}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

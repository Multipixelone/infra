#!/usr/bin/env python3
"""Write 0-3 nudge lines to sensor.fridge_nudges for the kitchen-iPad fridge dashboard.

Reads household state from HA's REST API (todos, calendars, weather, presence),
flags overdue / due-today chores and minutes-until-event in Python (LLM date
math is unreliable), asks OpenAI for a strict JSON object of ranked nudge
lines, and POSTs the result to sensor.fridge_nudges with state = first line,
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
    for entry in forecast[:6]:
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
        calendars[key] = {
            "state": s.get("state"),
            "message": attrs.get("message"),
            "start_time": start,
            "end_time": attrs.get("end_time"),
            "all_day": attrs.get("all_day"),
            "minutes_until_start": minutes_until(start, now),
            "starts_today": start_date == today if start_date else None,
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


def call_llm(facts: dict) -> list[str]:
    system = (SKILL_DIR / "SKILL.md").read_text()
    user = "Facts:\n" + json.dumps(facts, indent=2, default=str)
    client = OpenAI(timeout=30.0)
    resp = client.chat.completions.create(
        model=MODEL,
        response_format={"type": "json_object"},
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    )
    text = resp.choices[0].message.content or "{}"
    obj = json.loads(text)
    lines = obj.get("lines")
    if not isinstance(lines, list):
        raise ValueError(f"non-list lines field: {text!r}")
    cleaned: list[str] = []
    for entry in lines:
        if not isinstance(entry, str):
            raise ValueError(f"non-string line: {entry!r}")
        s = entry.strip()
        if s:
            cleaned.append(s)
    return cleaned[:3]


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

    try:
        lines = call_llm(facts)
    except Exception as e:
        print(f"nudge-writer: LLM call failed: {e}", file=sys.stderr)
        return 1

    try:
        post_sensor(lines, VALID_MINUTES)
    except Exception as e:
        print(f"nudge-writer: HA POST failed: {e}", file=sys.stderr)
        return 1

    print(f"nudge-writer: posted {len(lines)} line(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Compute the sleep-adaptive morning nudge time for the morning-routine skill.

Reads last night's sleep from the Apple Health bridge output and prints ONE
JSON line, e.g.:
  {"nudge_at": "2026-05-23T08:18:00-04:00", "mode": "normal", "reason": "..."}

This is deterministic on purpose. Scheduling should never be improvised by the
model. The planner cron calls this, reads `nudge_at`, then schedules the single
real nudge with `openclaw cron add --at <nudge_at>`.

Python 3.9+ (uses zoneinfo). stdlib only.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

# --- config: tweak these to taste -------------------------------------------
TZ = ZoneInfo(os.environ.get("ROUTINE_TZ", "America/New_York"))  # <FILL IN> your tz
HEALTH_FILE = os.environ.get(
    "HEALTH_FILE", os.path.expanduser("~/.openclaw/workspace/health-data.json")
)
BUFFER_MIN = 30  # nudge this many minutes after you actually woke
EARLIEST = time(7, 0)  # never nudge before this
LATEST = time(10, 30)  # hard ceiling; after this the day just stays quiet
FALLBACK = time(8, 30)  # used when there's no usable sleep data
SHORT_SLEEP_MIN = (
    6 * 60
)  # under this -> nudge leads with the floor, not the full routine
# ----------------------------------------------------------------------------


def _clamp(dt: datetime) -> datetime:
    lo = datetime.combine(dt.date(), EARLIEST, TZ)
    hi = datetime.combine(dt.date(), LATEST, TZ)
    return max(lo, min(dt, hi))


def _parse_sleep(data: dict):
    """Return (sleep_end: datetime|None, minutes_asleep: float|None).

    Bridges differ in their JSON shape. The lookups below cover the common
    Health Auto Export / Scriptable-bridge field names. >>> Map these to YOUR
    bridge's actual keys once you see its output. <<<
    """
    m = data.get("metrics", data)  # some bridges nest under "metrics"
    sleep = m.get("sleep") or m.get("sleep_analysis") or {}
    if isinstance(sleep, list):
        sleep = sleep[-1] if sleep else {}

    end_raw = (
        sleep.get("end")
        or sleep.get("sleepEnd")
        or sleep.get("wake_time")
        or sleep.get("endDate")
    )
    sleep_end = None
    if end_raw:
        try:
            sleep_end = datetime.fromisoformat(
                str(end_raw).replace("Z", "+00:00")
            ).astimezone(TZ)
        except ValueError:
            sleep_end = None

    minutes = (
        sleep.get("asleep_minutes")
        or sleep.get("total_sleep_minutes")
        or sleep.get("minutesAsleep")
    )
    if minutes is None:
        hours = sleep.get("asleep_hours")
        if hours is not None:
            minutes = float(hours) * 60
    return sleep_end, (float(minutes) if minutes is not None else None)


def main() -> int:
    today = datetime.now(TZ).date()
    out = {"mode": "normal"}

    try:
        with open(HEALTH_FILE) as fh:
            data = json.load(fh)
        sleep_end, minutes = _parse_sleep(data)
    except (OSError, json.JSONDecodeError):
        sleep_end, minutes = None, None

    # No fresh sleep record (watch died, not worn, sync didn't land) -> fall back.
    # The day must never depend on the data being there.
    if sleep_end is None or sleep_end.date() != today:
        out["nudge_at"] = datetime.combine(today, FALLBACK, TZ).isoformat()
        out["reason"] = "no_usable_sleep_data"
    else:
        target = _clamp(sleep_end + timedelta(minutes=BUFFER_MIN))
        out["nudge_at"] = target.isoformat()
        out["reason"] = f"sleep_end={sleep_end.isoformat()}"

    # Short / broken night = highest cascade-risk morning -> lead with the floor.
    if minutes is not None and minutes < SHORT_SLEEP_MIN:
        out["mode"] = "short"

    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

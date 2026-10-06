"""Structured filtering and random album selection; no beets query strings."""

import json
import math
import os
import re
import subprocess
from datetime import datetime, timezone

from .errors import invalid
from .library import normalize, number


def next_commute_duration():
    """Return persisted travel_minutes for the earliest future departure.

    Compare timezone-aware leave_at instants against the current UTC clock;
    equal departures retain payload order. Status covers the current logical
    NYC day. Skip unusable departures, but do not substitute a later trip if
    the next trip's duration is missing (commute_duration_missing), null
    (commute_duration_unavailable), or invalid (commute_duration_invalid).

    travel_minutes excludes scheduling buffers and preserves fractional minutes.
    It can be available independently of arrive_at or a plan error. Never infer
    travel from event start or arrival timestamps, including cached arrivals.

    Failures return (None, reason): commute_command_unavailable,
    commute_command_failed, commute_timeout, commute_invalid_payload,
    commute_no_plans, or commute_no_upcoming_plan. The caller keeps its 45-minute
    fallback. This adapter never invokes routing or modifies saved plans.
    """
    try:
        result = subprocess.run(
            [
                os.environ.get("LISTEN_COMMUTECOMPASS", "commutecompass-skill"),
                "status",
                "--json",
            ],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None, "commute_timeout"
    except UnicodeError:
        return None, "commute_invalid_payload"
    except (OSError, ValueError):
        return None, "commute_command_unavailable"
    if result.returncode != 0:
        return None, "commute_command_failed"
    try:
        payload = json.loads(result.stdout)
    except (TypeError, ValueError, RecursionError):
        return None, "commute_invalid_payload"
    if not isinstance(payload, dict) or not isinstance(payload.get("plans"), list):
        return None, "commute_invalid_payload"
    plans = payload["plans"]
    if any(not isinstance(plan, dict) for plan in plans):
        return None, "commute_invalid_payload"
    if not plans:
        return None, "commute_no_plans"

    now = datetime.now(timezone.utc)
    upcoming = []
    for plan in plans:
        leave_at = plan.get("leave_at")
        if not isinstance(leave_at, str):
            continue
        try:
            departure = datetime.fromisoformat(leave_at)
            if departure.utcoffset() is None:
                continue
            departure = departure.astimezone(timezone.utc)
        except (ValueError, OverflowError):
            continue
        if departure > now:
            upcoming.append((departure, plan))
    if not upcoming:
        return None, "commute_no_upcoming_plan"
    plan = min(upcoming, key=lambda candidate: candidate[0])[1]
    if "travel_minutes" not in plan:
        return None, "commute_duration_missing"
    value = plan["travel_minutes"]
    if value is None:
        return None, "commute_duration_unavailable"
    if type(value) not in (int, float):
        return None, "commute_duration_invalid"
    try:
        minutes = float(value)
    except (ValueError, OverflowError):
        return None, "commute_duration_invalid"
    if not math.isfinite(minutes) or minutes <= 0:
        return None, "commute_duration_invalid"
    return minutes, None


def cap_for(max_minutes):
    if max_minutes is not None:
        return {"minutes": max_minutes, "source": "flag", "reason": None}
    minutes, reason = next_commute_duration()
    if number(minutes, positive=True) is not None:
        return {"minutes": minutes, "source": "commutecompass", "reason": None}
    return {"minutes": 45, "source": "default", "reason": reason}


def date_bound(text):
    try:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text):
            value = datetime.fromisoformat(text).replace(tzinfo=timezone.utc)
        else:
            value = datetime.fromisoformat(text.replace("Z", "+00:00"))
            if value.tzinfo is None:
                raise ValueError("Timezone required")
        return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
    except ValueError as exc:
        raise invalid("Dates must be YYYY-MM-DD or ISO 8601 with an offset.") from exc


def bounds(values, names, minimum):
    output = {}
    for value in values:
        name, separator, text = value.partition("=")
        score = number(text, score=True)
        if not separator or name not in names or score is None:
            raise invalid(
                "Score bounds require a known NAME=VALUE with VALUE in [0,1]."
            )
        if name in output:
            score = max(score, output[name]) if minimum else min(score, output[name])
        output[name] = score
    return output


def filters_for(args, names):
    filters = {
        key: list(getattr(args, key))
        for key in (
            "artist",
            "exclude_artist",
            "genre",
            "exclude_genre",
            "label",
            "exclude_label",
            "rosamerica",
        )
    }
    for values in filters.values():
        if any(not normalize(value) for value in values):
            raise invalid("Filter text must not be empty.")
    filters.update(
        {
            "year_from": args.year_from,
            "year_to": args.year_to,
            "decade": None,
            "min_minutes": args.min_minutes,
            "bpm_min": args.bpm_min,
            "bpm_max": args.bpm_max,
            "added_after": date_bound(args.added_after) if args.added_after else None,
            "added_before": date_bound(args.added_before)
            if args.added_before
            else None,
            "mirex_clusters": sorted(set(args.mirex_cluster)),
            "moods": sorted(
                set(
                    args.mood
                    + (["relaxed"] if args.relaxed else [])
                    + (["instrumental"] if args.instrumental else [])
                )
            ),
            "avoid_moods": sorted(set(args.avoid_mood)),
            "min_scores": bounds(args.min_score, names, True),
            "max_scores": bounds(args.max_score, names, False),
            "scored_only": args.scored_only,
        }
    )
    if args.decade is not None:
        text = args.decade.removesuffix("s")
        if not re.fullmatch(r"\d{4}", text) or int(text) % 10:
            raise invalid("--decade requires a decade such as 1990 or 1990s.")
        decade = int(text)
        filters["decade"] = decade
        filters["year_from"] = max(args.year_from or decade, decade)
        filters["year_to"] = min(
            args.year_to if args.year_to is not None else decade + 9, decade + 9
        )
    requested = (
        set(filters["moods"] + filters["avoid_moods"])
        | filters["min_scores"].keys()
        | filters["max_scores"].keys()
    )
    if requested - names:
        raise invalid("Unknown mood; use listen moods to list available names.")
    if args.scored_only and not requested:
        raise invalid("--scored-only needs a mood preference or score bound.")
    if set(filters["moods"]) & set(filters["avoid_moods"]):
        raise invalid("A mood cannot be both favored and avoided.")
    for low, high in (
        ("year_from", "year_to"),
        ("bpm_min", "bpm_max"),
        ("added_after", "added_before"),
    ):
        lo, hi = filters[low], filters[high]
        if lo is not None and hi is not None:
            if low == "added_after":
                empty = datetime.fromisoformat(lo) >= datetime.fromisoformat(hi)
            else:
                empty = lo > hi
            if empty:
                raise invalid(
                    f"{low.replace('_', '-')} and {high.replace('_', '-')} have an empty range."
                )
    for name in filters["min_scores"].keys() & filters["max_scores"].keys():
        if filters["min_scores"][name] > filters["max_scores"][name]:
            raise invalid("Mood score bounds have an empty range.")
    return filters


def filter_reasons(album, filters):
    reasons = []
    for key, values in (
        ("artist", [album["albumartist"]]),
        ("genre", album["genres"]),
        ("label", [album["label"] or ""]),
    ):
        excludes = filters["exclude_" + key]
        if excludes and any(
            normalize(term) in normalize(value) for term in excludes for value in values
        ):
            reasons.append("exclude-" + key)
    for key, value, minimum in (
        ("year_from", album["year"], True),
        ("year_to", album["year"], False),
        ("bpm_min", album["bpm"], True),
        ("bpm_max", album["bpm"], False),
        (
            "min_minutes",
            album["length_seconds"] / 60
            if album["length_seconds"] is not None
            else None,
            True,
        ),
    ):
        bound = filters[key]
        if bound is not None and (
            value is None or (value < bound if minimum else value > bound)
        ):
            reasons.append(key.replace("_", "-"))
    for key in ("added_after", "added_before"):
        if filters[key] is not None:
            value = datetime.fromisoformat(album["added"]) if album["added"] else None
            bound = datetime.fromisoformat(filters[key])
            if value is None or (
                value <= bound if key == "added_after" else value >= bound
            ):
                reasons.append(key.replace("_", "-"))
    if (
        filters["mirex_clusters"]
        and album["mood_mirex"]["cluster"] not in filters["mirex_clusters"]
    ):
        reasons.append("mirex-cluster")
    requested = (
        set(filters["moods"] + filters["avoid_moods"])
        | filters["min_scores"].keys()
        | filters["max_scores"].keys()
    )
    if filters["scored_only"] and any(
        not album["scores"][name]["present"] for name in requested
    ):
        reasons.append("scored-only")
    for key, minimum in (("min_scores", True), ("max_scores", False)):
        for name, bound in filters[key].items():
            value = album["scores"][name]["score"]
            if value is not None and (value < bound if minimum else value > bound):
                reasons.append("min-score" if minimum else "max-score")
    return sorted(set(reasons))

"""Replay Home Assistant device-tracker history into Dawarich."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


class BackfillError(RuntimeError):
    """A user-actionable backfill failure."""


def required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise BackfillError(f"{name} is not set")
    return value


def read_secret(path: str) -> str:
    value = pathlib.Path(path).read_text(encoding="utf-8").strip()
    if not value:
        raise BackfillError(f"secret file is empty: {path}")
    return value


def request_json(
    url: str,
    token: str,
    *,
    payload: dict[str, Any] | None = None,
    extra_headers: dict[str, str] | None = None,
    attempts: int = 8,
) -> Any:
    data = None
    method = "GET"
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {token}",
    }
    if extra_headers is not None:
        headers.update(extra_headers)
    if payload is not None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        method = "POST"
        headers["Content-Type"] = "application/json"

    for attempt in range(1, attempts + 1):
        request = urllib.request.Request(
            url,
            data=data,
            headers=headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read()
                try:
                    return json.loads(body) if body else None
                except json.JSONDecodeError as error:
                    raise BackfillError(
                        f"{method} request returned invalid JSON"
                    ) from error
        except urllib.error.HTTPError as error:
            body = error.read(2048).decode("utf-8", errors="replace")
            detail = body or error.headers.get("Location", "")
            # Retrying an upload is safe: Dawarich upserts on user, timestamp,
            # and coordinates.
            if error.code < 500 or attempt == attempts:
                raise BackfillError(
                    f"{method} request returned HTTP {error.code}: {detail}"
                ) from error
        except urllib.error.URLError as error:
            if attempt == attempts:
                raise BackfillError(
                    f"{method} request failed: {error.reason}"
                ) from error

        time.sleep(min(2 ** (attempt - 1), 5))

    raise AssertionError("request retry loop exited unexpectedly")


def history_url(
    base_url: str, entity_id: str, start: dt.datetime, end: dt.datetime
) -> str:
    start_text = start.isoformat().replace("+00:00", "Z")
    end_text = end.isoformat().replace("+00:00", "Z")
    query = urllib.parse.urlencode(
        {
            "filter_entity_id": entity_id,
            "end_time": end_text,
            # Do not turn HA's synthesized state at the exact start boundary
            # into a fake Dawarich point.
            "skip_initial_state": "",
            "significant_changes_only": "0",
        }
    )
    encoded_start = urllib.parse.quote(start_text, safe="")
    return f"{base_url.rstrip('/')}/api/history/period/{encoded_start}?{query}"


def finite_number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def utc_timestamp(value: Any) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.UTC)
    # Dawarich stores timestamps as integer Unix seconds. Normalize before
    # deduplication so multiple HA updates within one second do not collapse
    # only after reaching the API.
    return (
        parsed.astimezone(dt.UTC)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def history_to_locations(history: Any, entity_id: str) -> list[dict[str, Any]]:
    if not isinstance(history, list):
        raise BackfillError("Home Assistant returned an unexpected history response")

    records: list[dict[str, Any]] = []
    for entity_history in history:
        if not isinstance(entity_history, list):
            continue
        records.extend(record for record in entity_history if isinstance(record, dict))

    locations: list[dict[str, Any]] = []
    seen: set[tuple[str, float, float]] = set()
    for record in records:
        attributes = record.get("attributes")
        if not isinstance(attributes, dict):
            continue

        latitude = finite_number(attributes.get("latitude"))
        longitude = finite_number(attributes.get("longitude"))
        timestamp = utc_timestamp(
            record.get("last_updated") or record.get("last_changed")
        )
        if latitude is None or longitude is None or timestamp is None:
            continue
        if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
            continue
        if latitude == 0 and longitude == 0:
            continue

        dedup_key = (timestamp, latitude, longitude)
        if dedup_key in seen:
            continue
        seen.add(dedup_key)

        properties: dict[str, Any] = {
            "timestamp": timestamp,
            "device_id": entity_id,
        }
        optional_properties = {
            "altitude": attributes.get("altitude"),
            "horizontal_accuracy": attributes.get("gps_accuracy"),
            "vertical_accuracy": attributes.get("vertical_accuracy"),
            "course": attributes.get("course"),
        }
        for name, raw_value in optional_properties.items():
            value = finite_number(raw_value)
            if value is not None:
                properties[name] = value

        battery_level = finite_number(attributes.get("battery_level"))
        if battery_level is not None and 0 <= battery_level <= 100:
            properties["battery_level"] = battery_level / 100

        locations.append(
            {
                "type": "Feature",
                "geometry": {
                    "type": "Point",
                    "coordinates": [longitude, latitude],
                },
                "properties": properties,
            }
        )

    locations.sort(key=lambda location: location["properties"]["timestamp"])
    return locations


def dawarich_api_key() -> str:
    if os.geteuid() != 0:
        raise BackfillError("the applied backfill must run as root")

    database_name = required_env("DAWARICH_DATABASE_NAME")
    database_user = required_env("DAWARICH_DATABASE_USER")
    psql = required_env("DAWARICH_PSQL")
    runuser = required_env("DAWARICH_RUNUSER")
    sql = (
        "SELECT api_key FROM users "
        "WHERE deleted_at IS NULL AND status IN (1, 2) "
        "AND email <> 'demo@dawarich.app' "
        "AND api_key IS NOT NULL AND api_key <> '' "
        "ORDER BY id;"
    )
    completed = subprocess.run(
        [
            runuser,
            "--user",
            database_user,
            "--",
            psql,
            "--no-psqlrc",
            "--tuples-only",
            "--no-align",
            "--set",
            "ON_ERROR_STOP=1",
            "--dbname",
            database_name,
            "--command",
            sql,
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        message = completed.stderr.strip() or "psql failed"
        raise BackfillError(f"could not read the Dawarich account: {message}")

    keys = [line.strip() for line in completed.stdout.splitlines() if line.strip()]
    if not keys:
        raise BackfillError("Dawarich has no active non-demo account with an API key")
    if len(keys) != 1:
        raise BackfillError(
            "Dawarich has multiple active non-demo accounts; refusing to guess which one owns "
            "this tracker"
        )
    return keys[0]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--entity-id", default="device_tracker.nougat")
    parser.add_argument("--days", type=int, default=21)
    parser.add_argument("--batch-size", type=int, default=500)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="upload the points; without this flag the command is a dry run",
    )
    args = parser.parse_args()
    if args.days < 1:
        parser.error("--days must be at least 1")
    if not 1 <= args.batch_size <= 1000:
        parser.error("--batch-size must be between 1 and 1000")
    return args


def main() -> int:
    args = parse_args()
    end = dt.datetime.now(dt.UTC)
    start = end - dt.timedelta(days=args.days)

    ha_url = required_env("HA_URL")
    ha_token = read_secret(required_env("HA_TOKEN_FILE"))
    history = request_json(history_url(ha_url, args.entity_id, start, end), ha_token)
    locations = history_to_locations(history, args.entity_id)
    if not locations:
        raise BackfillError(
            f"Home Assistant returned no usable locations for {args.entity_id}"
        )

    first = locations[0]["properties"]["timestamp"]
    last = locations[-1]["properties"]["timestamp"]
    print(
        f"Found {len(locations)} locations for {args.entity_id} from {first} through {last}.",
        flush=True,
    )
    if not args.apply:
        print("Dry run complete; no points were uploaded.", flush=True)
        return 0

    api_key = dawarich_api_key()
    dawarich_url = required_env("DAWARICH_URL").rstrip("/") + "/api/v1/points"
    dawarich_headers = {
        "Host": required_env("DAWARICH_HOST"),
        "X-Forwarded-Proto": "https",
    }
    submitted = 0
    for offset in range(0, len(locations), args.batch_size):
        batch = locations[offset : offset + args.batch_size]
        response = request_json(
            dawarich_url,
            api_key,
            payload={"locations": batch},
            extra_headers=dawarich_headers,
        )
        returned = response.get("data") if isinstance(response, dict) else None
        if not isinstance(returned, list) or len(returned) != len(batch):
            returned_count = len(returned) if isinstance(returned, list) else "non-list"
            raise BackfillError(
                "Dawarich returned an unexpected batch response: "
                f"expected {len(batch)} points, got {returned_count}"
            )
        submitted += len(batch)
        print(f"Submitted {submitted}/{len(locations)} locations.", flush=True)

    print(
        f"Backfill complete: {submitted} locations submitted to Dawarich.", flush=True
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (BackfillError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)

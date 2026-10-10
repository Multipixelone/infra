"""Validate life events and add their public bookmarks to album-graph JSON."""

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker, ValidationError

ADDED_TIMESTAMP = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})$"
)


def load_events(data_path, schema_path):
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    events = json.loads(data_path.read_text(encoding="utf-8"))
    Draft202012Validator(schema, format_checker=FormatChecker()).validate(events)
    seen = set()
    for event in events:
        if event["id"] in seen:
            raise ValueError(f"Duplicate life event ID: {event['id']}")
        seen.add(event["id"])
        if "end_date" in event and event["end_date"] < event["date"]:
            raise ValueError(f"Life event end_date precedes date: {event['id']}")
    return events


def added_timestamp(value):
    """Read the export's ISO timestamps, ignoring unknown historical dates."""
    if not isinstance(value, str) or not ADDED_TIMESTAMP.fullmatch(value):
        return None
    try:
        return datetime.fromisoformat(value).astimezone(timezone.utc)
    except (ValueError, OverflowError):
        return None


def add_bookmarks(graph, events):
    bookmarks = [
        {
            "id": event["id"],
            "date": event["date"],
            "end_date": event.get("end_date"),
            "precision": event["precision"],
            "title": event["title"],
            "category": event["category"],
        }
        for event in events
        if event["visibility"] == "public"
    ]
    added = [
        timestamp
        for album in graph.get("albums", [])
        if (timestamp := added_timestamp(album.get("added"))) is not None
    ]
    if added:
        bookmarks.append(
            {
                "id": "beets-library-import",
                "date": min(added).date().isoformat(),
                "end_date": None,
                "precision": "day",
                "title": "Library imported into beets",
                "category": "music",
            }
        )
    bookmarks.sort(key=lambda event: (event["date"], event["id"]))
    return graph | {"bookmarks": bookmarks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate", help="Validate a life events file")
    export = commands.add_parser("export", help="Enrich a staged graph in place")
    for command in (validate, export):
        command.add_argument("data", type=Path)
        command.add_argument("schema", type=Path)
    export.add_argument("graph", type=Path)
    args = parser.parse_args()
    try:
        events = load_events(args.data, args.schema)
        if args.command == "export":
            graph = json.loads(args.graph.read_text(encoding="utf-8"))
            enriched = add_bookmarks(graph, events)
            args.graph.write_text(
                json.dumps(enriched, ensure_ascii=False, separators=(",", ":")) + "\n",
                encoding="utf-8",
            )
    except ValidationError as exc:
        # Do not echo an instance: a validation error could include a note.
        location = "/".join(str(part) for part in exc.absolute_path) or "/"
        parser.exit(1, f"Invalid life events at {location}: {exc.validator}\n")
    except (OSError, ValueError) as exc:
        parser.exit(1, f"Life events processing failed: {exc}\n")


if __name__ == "__main__":
    main()

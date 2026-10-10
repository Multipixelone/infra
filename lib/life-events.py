"""Validate canonical life events without requiring Nix."""

import argparse
import json
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker, ValidationError


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate", help="Validate a life events file")
    validate.add_argument("data", type=Path)
    validate.add_argument("schema", type=Path)
    args = parser.parse_args()
    try:
        load_events(args.data, args.schema)
    except ValidationError as exc:
        # Do not echo an instance: a validation error could include a note.
        location = "/".join(str(part) for part in exc.absolute_path) or "/"
        parser.exit(1, f"Invalid life events at {location}: {exc.validator}\n")
    except (OSError, ValueError) as exc:
        parser.exit(1, f"Life events validation failed: {exc}\n")


if __name__ == "__main__":
    main()

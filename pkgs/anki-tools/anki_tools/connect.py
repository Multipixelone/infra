"""anki-connect: run an arbitrary AnkiConnect action from the command line.

Examples:
  anki-connect version
  anki-connect deckNames
  anki-connect findNotes '{"query": "deck:Spanish"}'
  anki-connect guiBrowse '{"query": "tag:exam1"}'
"""

from __future__ import annotations

import argparse
import json
import sys

from ._ankiconnect import DEFAULT_ENDPOINT, AnkiConnectError, invoke


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="anki-connect",
        description="Run an AnkiConnect action and print its JSON result.",
    )
    parser.add_argument("action", help="AnkiConnect action name, e.g. 'deckNames'")
    parser.add_argument(
        "params",
        nargs="?",
        help="action parameters as a JSON object string",
    )
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT, help="AnkiConnect URL")
    args = parser.parse_args(argv)

    try:
        params = json.loads(args.params) if args.params else {}
    except json.JSONDecodeError as e:
        print(f"error: params is not valid JSON: {e}", file=sys.stderr)
        return 1
    if not isinstance(params, dict):
        print("error: params must be a JSON object", file=sys.stderr)
        return 1

    try:
        result = invoke(args.action, params, args.endpoint)
    except AnkiConnectError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

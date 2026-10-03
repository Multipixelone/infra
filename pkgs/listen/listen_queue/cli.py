"""Terminal and stable JSON interfaces for the listening queue."""

import argparse
import json
import os
import sqlite3
import sys
from contextlib import redirect_stdout
from pathlib import Path

from .errors import ListenError, invalid
from .library import Queue, number, shared_lock
from .plex import seed, sync
from .selection import pick

EXIT_HELP = """Exit codes: 0 success; 64 invalid arguments/mood; 65 not found;
66 ambiguous/needs_album/not_queued/already_seeded; 70 internal failure;
75 backend unavailable; 78 configuration/state invalid.
JSON schema 1: {schema, command, ok, data} or
{schema, command, ok, error: {code, message, details}}.
Configuration: LISTEN_BEETS_CONFIG (default ~/.config/beets/config.yaml),
LISTEN_BEETS_LOCK (default config directory/.import.lock),
LISTEN_STATE_DIR (default $XDG_STATE_HOME/listen or ~/.local/state/listen),
PLEXAPI_CONFIG_PATH (existing python-plexapi configuration).
LISTEN_PLEX_SOURCE (queue title) and LISTEN_PLEX_DONE_SOURCE (listened title)
are required for seed-plex and sync-plex; exact titles after case/diacritic/whitespace
normalization, preserving punctuation. There are no default source titles.
Seed conflicts become listened. Apply sets listened_at to the import time,
updates beets album fields and a local receipt, never Plex; further applies
are refused once the receipt exists. Dry-runs remain repeatable.
sync-plex is repeatable and dry-run by default. Apply imports only unmarked
albums; every existing listen_state is preserved, including dropped. New
albums in both sources become listened. Sync never changes the seed receipt.
most-played sums track lastfm_play_count (fallback: legacy play_count) and
sorts descending, with ties by normalized artist/title, then album ID.
Its default is any album with plays > 0; --listened-only instead includes
all marked-listened albums, even with zero plays. plays_per_track divides
by all album tracks. Play counts describe tracks played, not full album listens.
No command writes media tags. No arbitrary beets query syntax is accepted.
"""


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise invalid(message)


def positive(text):
    value = number(text, positive=True)
    if value is None:
        raise argparse.ArgumentTypeError("must be a positive finite number")
    return value


def positive_int(text):
    try:
        value = int(text)
        if value <= 0:
            raise ValueError()
        return value
    except ValueError as exc:
        raise argparse.ArgumentTypeError("must be a positive integer") from exc


def parser():
    root = Parser(
        prog="listen",
        description="Queue, choose, and finish beets albums.",
        epilog=EXIT_HELP,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    root.add_argument(
        "--json", action="store_true", help="emit a schema 1 JSON envelope"
    )
    commands = root.add_subparsers(dest="command", required=True)
    for command in (
        "add",
        "done",
        "drop",
        "list",
        "pick",
        "moods",
        "most-played",
        "seed-plex",
        "sync-plex",
    ):
        sub = commands.add_parser(
            command,
            epilog=EXIT_HELP,
            formatter_class=argparse.RawDescriptionHelpFormatter,
        )
        sub.add_argument("--json", action="store_true", default=argparse.SUPPRESS)
        if command in ("add", "done", "drop"):
            sub.add_argument(
                "text",
                nargs="?",
                help="literal albumartist/album search (quote multiple words)",
            )
            sub.add_argument(
                "--id", type=positive_int, help="authoritative beets album ID"
            )
            sub.set_defaults(handler=command)
        elif command == "list":
            sub.add_argument(
                "--state",
                choices=["queued", "listened", "dropped", "all"],
                default="queued",
            )
        elif command == "most-played":
            sub.add_argument(
                "--listened-only",
                action="store_true",
                help="rank marked-listened albums, including those with zero plays",
            )
        elif command in ("seed-plex", "sync-plex"):
            sub.add_argument(
                "--apply",
                action="store_true",
                help=("apply once" if command == "seed-plex" else "apply new matches")
                + "; otherwise dry-run (never writes to Plex)",
            )
        elif command == "pick":
            sub.add_argument(
                "--choose",
                type=positive_int,
                help="record Finn's explicitly chosen queued album; exclusive of other pick options",
            )
            sub.add_argument("--count", type=positive_int, default=3)
            sub.add_argument(
                "--max-minutes",
                type=positive,
                help="soft cap; defaults to commute duration, then 45",
            )
            sub.add_argument(
                "--pool",
                action="store_true",
                help="show ALL queued albums, including filter rejections; ignores count",
            )
            sub.add_argument(
                "--relaxed", action="store_true", help="alias for --mood relaxed"
            )
            sub.add_argument(
                "--instrumental",
                action="store_true",
                help="alias for --mood instrumental",
            )
            for key in (
                "artist",
                "exclude-artist",
                "genre",
                "exclude-genre",
                "label",
                "exclude-label",
                "rosamerica",
            ):
                sub.add_argument(
                    "--" + key,
                    action="append",
                    default=[],
                    help="repeat for alternatives; literal matching",
                )
            for key in ("mood", "avoid-mood"):
                sub.add_argument(
                    "--" + key,
                    action="append",
                    default=[],
                    metavar="NAME",
                    help="repeatable score preference; unknown scores remain eligible",
                )
            for key in ("min-score", "max-score"):
                sub.add_argument(
                    "--" + key,
                    action="append",
                    default=[],
                    metavar="NAME=VALUE",
                    help="inclusive [0,1] bound; missing scores remain eligible",
                )
            for key in ("year-from", "year-to"):
                sub.add_argument("--" + key, type=positive_int)
            sub.add_argument(
                "--decade", help="e.g. 1990 or 1990s; intersect explicit year bounds"
            )
            for key in ("min-minutes", "bpm-min", "bpm-max"):
                sub.add_argument(
                    "--" + key,
                    type=positive,
                    help="hard inclusive bound; missing values fail",
                )
            for key in ("added-after", "added-before"):
                sub.add_argument(
                    "--" + key,
                    help="strict date bound; YYYY-MM-DD (UTC) or ISO 8601 with offset",
                )
            sub.add_argument(
                "--mirex-cluster",
                action="append",
                type=int,
                choices=range(1, 6),
                default=[],
            )
            sub.add_argument(
                "--scored-only",
                action="store_true",
                help="require all referenced mood scores",
            )
    return root


def dispatch(args, queue, argv):
    if args.command in ("add", "done", "drop"):
        if args.command != "add" and args.text is not None and args.id is not None:
            raise invalid("Supply text or --id, not both.")
        if args.command == "add" and args.text is None and args.id is None:
            raise invalid("add needs album text or --id.")
        return queue.mark(args.command, args.text, args.id)
    if args.command == "list":
        return {
            "state": args.state,
            "albums": [queue.metadata(a) for a in queue.albums(args.state)],
        }
    if args.command == "moods":
        albums = [queue.metadata(a) for a in queue.albums()]
        return {
            "moods": [
                {
                    "name": name,
                    "field": field,
                    "scored_queued_albums": sum(
                        a["scores"][name]["present"] for a in albums
                    ),
                }
                for name, field in sorted(queue.fields.items())
            ],
            "queued_albums": len(albums),
        }
    if args.command == "seed-plex":
        return seed(queue, args.apply)
    if args.command == "sync-plex":
        return sync(queue, args.apply)
    if args.command == "most-played":
        return queue.most_played(args.listened_only)
    if args.choose is not None:
        if any(
            value.startswith("--") and value.split("=")[0] not in ("--json", "--choose")
            for value in argv
        ):
            raise invalid("--choose is exclusive of all other pick options.")
        return queue.choose(args.choose)
    return pick(queue, args)


def album_line(album):
    length = album["length_seconds"]
    duration = f"{length / 60:.1f} min" if length is not None else "length unknown"
    score_text = ", ".join(
        f"{name}={entry['score']:.2f}" if entry["present"] else f"{name}=?"
        for name, entry in album["scores"].items()
    )
    over = (
        f" (+{album['over_minutes']:.1f} min over)" if album.get("over_minutes") else ""
    )
    rejected = (
        f" [filtered: {', '.join(album['filter_reasons'])}]"
        if album.get("filter_reasons")
        else ""
    )
    metadata = [", ".join(album["genres"]), album["label"]]
    if album["bpm"] is not None:
        metadata.append(f"{album['bpm']:g} BPM")
    if album["mood_mirex"]["cluster"] is not None:
        metadata.append(f"MIREX {album['mood_mirex']['cluster']}")
    if album["genre_rosamerica"]["present"]:
        metadata.append(f"Rosamerica {album['genre_rosamerica']['genre']}")
    description = " | ".join(value for value in metadata if value)
    return f"[{album['id']}] {album['albumartist']} — {album['album']} ({album['year'] or '?'}, {album['track_count']} tracks, {duration}, {album['listen_state'] or 'unmarked'}){over}{rejected}\n  {description}\n  {score_text}"


def human(command, data):
    if command in ("add", "done", "drop"):
        print(f"{data['album']['listen_state']}: {album_line(data['album'])}")
    elif command == "pick" and data["mode"] == "choose":
        print("Chosen: " + album_line(data["chosen"]))
    elif command in ("pick", "list", "most-played"):
        if command == "pick":
            cap = data["cap"]
            print(
                f"Cap: {cap['minutes']:g} minutes ({cap['source']}{': ' + cap['reason'] if cap['reason'] else ''})"
            )
        for album in data["albums"]:
            if command == "most-played":
                average = album["plays_per_track"]
                print(
                    f"{album['play_count']} plays; "
                    + (
                        f"{average:.2f} per track"
                        if average is not None
                        else "no tracks"
                    )
                )
            print(album_line(album))
        if not data["albums"]:
            print("No albums.")
        if command == "pick":
            print("Record Finn's choice: listen pick --choose ID")
    elif command == "moods":
        for mood in data["moods"]:
            print(
                f"{mood['name']}: {mood['scored_queued_albums']}/{data['queued_albums']} queued albums scored"
            )
    else:
        print(
            "Applied."
            if data["applied"]
            else (
                "Dry-run; use --apply once to seed matches."
                if command == "seed-plex"
                else "Dry-run; use --apply to import new matches."
            )
        )
        if data.get("already_seeded"):
            print("Already seeded; further apply runs are refused.")
        for state, group in data["groups"].items():
            counts = group["counts"]
            print(
                f"{state}: {counts['matched']} matched, {counts['unmatched']} unresolved "
                f"({counts['ambiguous']} ambiguous), {counts['planned']} planned albums"
                + (
                    f", {counts['skipped']} existing albums skipped"
                    if command == "sync-plex"
                    else ""
                )
            )
            for source in group["sources"]:
                print(f"Source: {source['kind']} {source['title']} [{source['id']}]")
            for result in group["matched"]:
                print(
                    ("Skipped existing" if result.get("skipped") else "Matched")
                    + f" ({result['method']}; target {result['effective_state']}): "
                    + album_line(result["album"])
                )
            for result in group["unmatched"]:
                item = result["plex_album"]
                print(
                    f"Unmatched ({result['reason']}): {item['albumartist']} — {item['album']}"
                )
                for album in result["candidates"]:
                    print(album_line(album))
        if data["overlap_ids"]:
            print(
                "In both sources; listened wins: "
                + ", ".join(map(str, data["overlap_ids"]))
            )


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    as_json = "--json" in argv
    candidate = next((value for value in argv if value != "--json"), None)
    command = (
        candidate
        if candidate
        in (
            "add",
            "done",
            "drop",
            "list",
            "pick",
            "moods",
            "most-played",
            "seed-plex",
            "sync-plex",
        )
        else None
    )
    try:
        args = parser().parse_args(argv)
        command, as_json = args.command, args.json
        config = Path(
            os.environ.get(
                "LISTEN_BEETS_CONFIG",
                Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
                / "beets/config.yaml",
            )
        )
        lock = os.environ.get("LISTEN_BEETS_LOCK", str(config.parent / ".import.lock"))
        state = os.environ.get(
            "LISTEN_STATE_DIR",
            str(
                Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
                / "listen"
            ),
        )
        if not config.is_file():
            raise ListenError(
                "configuration_invalid", "Beets configuration is missing.", 78
            )
        # Third-party diagnostics must never corrupt the single JSON envelope.
        with redirect_stdout(sys.stderr), shared_lock(lock):
            queue = Queue(config, state)
            data = dispatch(args, queue, argv)
        envelope = {"schema": 1, "command": command, "ok": True, "data": data}
        if as_json:
            print(json.dumps(envelope, ensure_ascii=False, allow_nan=False))
        else:
            human(command, data)
        return 0
    except ListenError as exc:
        error = exc
    except sqlite3.Error:
        error = ListenError("backend_unavailable", "Beets database is unavailable.", 75)
    except OSError:
        error = ListenError(
            "backend_unavailable", "Unable to access the library, lock, or state.", 75
        )
    except Exception as exc:  # noqa: BLE001 - CLI boundary guarantees the JSON error envelope.
        import confuse

        if isinstance(exc, confuse.ConfigError):
            error = ListenError(
                "configuration_invalid", "Invalid beets configuration.", 78
            )
        else:
            error = ListenError("internal_error", "Unexpected listen failure.", 70)
    envelope = {
        "schema": 1,
        "command": command,
        "ok": False,
        "error": {
            "code": error.code,
            "message": error.message,
            "details": error.details,
        },
    }
    if as_json:
        print(json.dumps(envelope, ensure_ascii=False, allow_nan=False))
    else:
        print(error.message, file=sys.stderr)
        for album in error.details.get("candidates", []):
            print(album_line(album), file=sys.stderr)
    return error.exit_code


if __name__ == "__main__":
    sys.exit(main())

"""Terminal and stable JSON interfaces for the listening queue."""

import argparse
import json
import os
import sqlite3
import sys
from contextlib import ExitStack, redirect_stdout
from pathlib import Path

from .discovery import discover
from .errors import ListenError, invalid
from .graph import Graph
from .library import Queue, number, retry_busy, shared_lock, state_lock, timeout_setting
from .plex import seed, sync

EXIT_HELP = """Exit codes: 0 success; 64 invalid arguments/mood; 65 not found;
66 ambiguous/needs_album/not_queued/already_seeded; 69 text embedding failure;
70 internal failure; 72 graph_unavailable (missing/unreadable export);
75 backend unavailable; 78 configuration/state invalid.
JSON schema 1: {schema, command, ok, data} or
{schema, command, ok, error: {code, message, details}}.
Configuration: LISTEN_BEETS_CONFIG (default ~/.config/beets/config.yaml),
LISTEN_BEETS_LOCK (default config directory/.import.lock),
LISTEN_BEETS_LOCK_TIMEOUT (seconds, default 30; 0 fails immediately if busy),
LISTEN_SQLITE_BUSY_TIMEOUT (read retry seconds, default 10),
LISTEN_STATE_DIR (default $XDG_STATE_HOME/listen or ~/.local/state/listen),
LISTEN_ALBUM_GRAPH (default /var/lib/beets-album-graph/albums.json),
LISTEN_TEXT_ENDPOINT (default http://127.0.0.1:8765/api/embed-text),
LISTEN_TEXT_TIMEOUT (positive seconds, default 15),
PLEXAPI_CONFIG_PATH (existing python-plexapi configuration).
Read commands and Plex dry-runs open beets read-only without the import lock.
Plain pick never saves a choice; pick --choose writes only private state,
using a separate state lock (5-second wait). Beets writers use the exclusive
import lock; receipt writers also use the state lock. Busy failures exit 75.
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

Discovery: pick defaults to one queued album, weighted-random from the top 5;
--library includes all beets albums. --count samples without replacement from
the highest 5 remaining albums per draw. find ranks the whole library, top 3
by default. --count overrides either default. Positive metadata/mood inputs
are soft preferences; exclusions and explicit bounds remain filters. Pick's
length cap is hard (including unknown lengths); find has no implicit cap.
--pool shows rejections, except missing graph inputs are always skipped.
--require KIND=VALUE adds a hard input (identical soft inputs are deduplicated).
Kinds: vibe, more-like, more-like-id, descriptor, mood, avoid-mood, artist,
genre, label, rosamerica, danceability, vocal. Bare relaxed, instrumental,
fresh, rediscover are also accepted. Example: --require 'descriptor=clap:lo-fi'.
--danceability MIN:MAX uses Essentia danceable probability, not raw danceability.
--instrumental remains the xtractor mood preference; --vocal instrumental uses
the observed Essentia voice_instrumental category, without inferring complements.
Album similarity uses style vectors when exported, otherwise CLAP text-space
audio vectors; vibe always uses CLAP text space. Reference albums are excluded.
Continuous learned scores/cosines use tie-aware library percentiles in [0,1];
constant columns and missing soft xtractor moods score 0.5. Metadata/category
matches score 0 or 1; repeated metadata alternatives use their maximum match.
Danceability scores 1 inside the range, else 1 minus distance to the range.
For p=plays_per_track, fresh=1/(1+p); rediscover=log1p(p)/(1+log1p(p)) times
clamp(days_since_listened_at/90,0,1). listened_at is a recency proxy, not a
last-play timestamp; unknown recency contributes zero. History is neutral
unless requested. Total score is the equal mean of components (0.5 if none);
pick weight is 1+score. JSON includes raw/normalized scores and why tags.
Hard thresholds: vibe population z>=0.5; album cosine>=0.7; relative
descriptors z>=0.5; trained probability/category descriptors>=0.05;
Essentia/xtractor probabilities>=0.5; avoid-mood<=0.5. Literal/category
requirements must match; danceability must be within range. Required fresh
needs p<=1; rediscover needs plays and known listened_at at least 90 days ago.
Missing hard values fail. Missing requested graph values are silently skipped,
with no coverage penalty. Valid exports older than 48h remain usable, marked
stale in JSON. Beets-only queries work without the export or text endpoint.
Malformed graph data is graph_invalid (78). Text errors (69) distinguish
text_embedding_unavailable, text_embedding_invalid and text_model_mismatch;
the endpoint model_id must exactly match the export. Vibes are 1–240 chars.
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
        "find",
        "descriptors",
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
        elif command in ("pick", "find"):
            if command == "pick":
                sub.add_argument(
                    "--choose",
                    type=positive_int,
                    help="record Finn's explicitly chosen queued album; exclusive of other pick options",
                )
                sub.add_argument(
                    "--library", action="store_true", help="search the whole library"
                )
                sub.add_argument(
                    "--pool",
                    action="store_true",
                    help="show all candidates and filter rejections; ignores count",
                )
            else:
                sub.set_defaults(choose=None, library=True, pool=False)
            sub.add_argument(
                "--count", type=positive_int, default=1 if command == "pick" else 3
            )
            sub.add_argument(
                "--max-minutes",
                type=positive,
                help="hard cap; pick defaults to commute duration, then 45; find has no default",
            )
            for key in ("vibe", "more-like", "descriptor"):
                sub.add_argument(
                    "--" + key,
                    action="append",
                    default=[],
                    help="repeatable soft preference",
                )
            sub.add_argument(
                "--more-like-id", action="append", type=positive_int, default=[]
            )
            sub.add_argument(
                "--danceability", action="append", default=[], metavar="MIN:MAX"
            )
            sub.add_argument(
                "--vocal",
                action="append",
                choices=("vocal", "instrumental"),
                default=[],
            )
            sub.add_argument(
                "--require",
                action="append",
                default=[],
                metavar="KIND=VALUE",
                help="add a hard input; see help epilog",
            )
            history = sub.add_mutually_exclusive_group()
            history.add_argument(
                "--fresh", action="store_true", help="prefer rarely played albums"
            )
            history.add_argument(
                "--rediscover",
                action="store_true",
                help="prefer familiar albums with old listened_at",
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
    if args.command == "descriptors":
        graph = Graph.read(required=True)
        return {
            "descriptors": [
                graph.catalog_info(identity) for identity in sorted(graph.catalog)
            ]
            + [
                {
                    "id": f"xtractor:{name}",
                    "label": name,
                    "source": "xtractor",
                    "kind": "probability",
                    "axis": "mood",
                    "field": field,
                }
                for name, field in sorted(queue.fields.items())
            ],
            "album_graph": graph.metadata,
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
    return discover(queue, args)


def access_mode(args):
    """Return (writes beets, writes private state) for every CLI command."""
    if args.command in ("add", "done", "drop"):
        return True, args.command != "add"
    if args.command in ("seed-plex", "sync-plex"):
        return args.apply, args.apply and args.command == "seed-plex"
    return False, args.command == "pick" and args.choose is not None


def execute(args, config, state, lock, argv):
    writes_beets, writes_state = access_mode(args)
    lock_timeout = timeout_setting("LISTEN_BEETS_LOCK_TIMEOUT", 30)
    read_timeout = timeout_setting("LISTEN_SQLITE_BUSY_TIMEOUT", 10)

    def operation():
        queue = Queue(config, state, read_only=not writes_beets)
        try:
            return dispatch(args, queue, argv)
        finally:
            queue.close()

    with ExitStack() as stack:
        # This order is shared by all writers. State-only choices cannot hold
        # the private lock while waiting for the import lock.
        if writes_beets:
            stack.enter_context(shared_lock(lock, lock_timeout))
        if writes_state:
            stack.enter_context(state_lock(state))
        if writes_beets:
            return operation()
        return retry_busy(operation, read_timeout)


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
    elif command in ("pick", "find", "list", "most-played"):
        if command in ("pick", "find") and data["cap"] is not None:
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
            if command in ("pick", "find"):
                print(
                    f"  score={album['score']:.3f}"
                    + (" | " + ", ".join(album["why"]) if album["why"] else "")
                )
        if not data["albums"]:
            print("No albums.")
        if command == "pick":
            print("Record Finn's choice: listen pick --choose ID")
        elif command == "find":
            print("Queue a discovery: listen add --id ID")
    elif command == "descriptors":
        for descriptor in data["descriptors"]:
            print(
                f"{descriptor['id']}: {descriptor['label']} ({descriptor['source']}; {descriptor['kind']})"
            )
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
            "find",
            "descriptors",
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
        with redirect_stdout(sys.stderr):
            data = execute(args, config, state, lock, argv)
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
        for descriptor in error.details.get("descriptor_candidates", []):
            print(descriptor["id"], file=sys.stderr)
    return error.exit_code


if __name__ == "__main__":
    sys.exit(main())

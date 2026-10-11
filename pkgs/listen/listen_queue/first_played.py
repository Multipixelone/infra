"""Manual, bounded Last.fm history scan; only apply writes album attributes."""

import json
import math
import os
import shlex
import sys
import tempfile
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from .errors import ListenError
from .library import Queue, normalize, number, shared_lock, timeout_setting

USER = "Tunnelmaker"
LIMIT = 200
METHOD = "user.getRecentTracks"
API = "https://ws.audioscrobbler.com/2.0/"
USER_AGENT = (
    "infra-listen/0.1.0 (manual bounded album first-played backfill; "
    "https://git.finnrut.is/tunnel/infra)"
)
FIELD = "lastfm_first_played"


def epoch(value):
    if isinstance(value, bool):
        return None
    value = number(value, positive=True)
    if value is not None:
        try:
            datetime.fromtimestamp(value, timezone.utc)
            return value
        except (ValueError, OverflowError, OSError):
            pass
    return None


def state_error(message):
    return ListenError("state_invalid", message, 78)


def atomic_write(path, raw):
    fd, temporary = tempfile.mkstemp(prefix=".first-played-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def api_key(path):
    """Read the existing agenix shell assignments without executing them."""
    if path is None:
        raise ListenError(
            "configuration_invalid", "A Last.fm credentials file is required.", 78
        )
    try:
        for line in Path(path).read_text().splitlines():
            tokens = shlex.split(line, comments=True)
            if tokens and tokens[0] == "export":
                tokens = tokens[1:]
            for token in tokens:
                if token.startswith("API_KEY="):
                    key = token.partition("=")[2]
                    if key and not any(char in key for char in "$`\n\r"):
                        return key
    except (OSError, ValueError):
        pass
    raise ListenError(
        "configuration_invalid", "Last.fm credentials lack a usable API_KEY.", 78
    )


class Cache:
    def __init__(self, root, library, cutoff):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        self.path = self.root / "checkpoint.json"
        identity = {
            "schema": 1,
            "library": os.path.realpath(library),
            "user": USER,
            "cutoff": cutoff,
            "method": METHOD,
            "limit": LIMIT,
        }
        try:
            self.state = json.loads(self.path.read_bytes())
            if any(self.state.get(key) != value for key, value in identity.items()):
                raise ValueError()
            if (
                not isinstance(self.state["next_page"], int)
                or self.state["next_page"] < 1
            ):
                raise ValueError()
            if (
                number(self.state["last_request"]) is None
                or self.state["last_request"] < 0
            ):
                raise ValueError()
            if self.state["total_pages"] is not None and (
                not isinstance(self.state["total_pages"], int)
                or self.state["total_pages"] < 0
            ):
                raise ValueError()
        except FileNotFoundError:
            if any(self.root.glob("page-*.json")):
                raise state_error("Cached pages have no checkpoint identity.") from None
            self.state = {
                **identity,
                "next_page": 1,
                "total_pages": None,
                "total_tracks": None,
                "last_request": 0,
            }
            self.save()
        except (ValueError, TypeError, KeyError, AttributeError):
            raise state_error(
                "Invalid or incompatible first-played checkpoint."
            ) from None

    def save(self):
        atomic_write(self.path, json.dumps(self.state).encode())

    def page_path(self, page):
        return self.root / f"page-{page:06d}.json"

    def request_started(self):
        # Persist attempts, including failures, so immediate resumes stay polite.
        remaining = 1 - (time.time() - self.state["last_request"])
        last_attempt = getattr(self, "last_attempt", None)
        if last_attempt is not None:
            # Wall time can jump during a long scan; use monotonic time within
            # this process and the persisted wall timestamp across restarts.
            remaining = max(remaining, 1 - (time.monotonic() - last_attempt))
        if remaining > 0:
            time.sleep(remaining)
        self.state["last_request"] = time.time()
        self.save()
        self.last_attempt = time.monotonic()

    def page(self, page, credentials, *, offline=False):
        path = self.page_path(page)
        cached = path.exists()
        if cached:
            raw = path.read_bytes()
        else:
            if offline or page < self.state["next_page"]:
                raise state_error("The completed scan is missing a cached page.")
            raw = fetch_page(self, page, api_key(credentials))
            # Keep the raw response even if validation fails. A rerun must not
            # spend another request on the same invalid page.
            atomic_write(path, raw)
        tracks, total, count = parse_page(raw, page, self.state["cutoff"])
        if self.state["total_pages"] not in (None, total) or self.state.get(
            "total_tracks"
        ) not in (None, count):
            raise state_error("Last.fm page totals changed; use a new cache directory.")
        self.state.update(
            total_pages=total,
            total_tracks=count,
            next_page=max(self.state["next_page"], page + 1),
        )
        self.save()
        return tracks, total, count, cached


def retry_after(headers):
    value = headers.get("Retry-After", "")
    try:
        return max(0, float(value))
    except ValueError:
        try:
            return max(0, parsedate_to_datetime(value).timestamp() - time.time())
        except (ValueError, TypeError, OverflowError):
            return 0


def fetch_page(cache, page, key):
    params = {
        "method": METHOD,
        "user": USER,
        "to": cache.state["cutoff"],
        "limit": LIMIT,
        "page": page,
        "format": "json",
        "api_key": key,
    }
    request = Request(API + "?" + urlencode(params), headers={"User-Agent": USER_AGENT})
    for attempt in range(7):
        cache.request_started()
        wait = 0
        try:
            with urlopen(request, timeout=30) as response:
                raw = response.read()
            payload = json.loads(raw)
            if "error" not in payload:
                # Never persist a response that echoes the credential.
                if key.encode() in raw:
                    raise state_error("Last.fm unexpectedly echoed a credential.")
                return raw
            transient = payload["error"] in (11, 16, 29)
        except HTTPError as exc:
            transient = exc.code == 429 or 500 <= exc.code <= 599
            wait = retry_after(exc.headers)
            exc.close()
        except (URLError, TimeoutError):
            transient = True
        except (ValueError, TypeError):
            transient = False
        if not transient or attempt == 6:
            # Exceptions and API messages can contain the request URL/API key.
            raise ListenError(
                "backend_unavailable",
                f"Last.fm page {page} failed; cached pages are safe to resume.",
                75,
            ) from None
        time.sleep(max(wait, min(2**attempt, 60)))


def parse_page(raw, page, cutoff):
    try:
        payload = json.loads(raw)["recenttracks"]
        attributes = payload["@attr"]
        total = int(attributes["totalPages"])
        count = int(attributes["total"])
        if int(attributes["page"]) != page or total < 0 or count < 0:
            raise ValueError()
        if attributes.get("user", USER).casefold() != USER.casefold():
            raise ValueError()
        if total != math.ceil(count / LIMIT) and not (count == 0 and total == 1):
            raise ValueError()
        tracks = payload.get("track", [])
        if isinstance(tracks, dict):
            tracks = [tracks]
        if not isinstance(tracks, list):
            raise TypeError()
        for track in tracks:
            if not isinstance(track, dict):
                raise TypeError()
            if track.get("@attr", {}).get("nowplaying") in ("true", True):
                continue
            stamp = epoch(track.get("date", {}).get("uts"))
            if stamp is not None and stamp > cutoff:
                raise ValueError()
        if count and not tracks:
            raise ValueError()
        return tracks, total, count
    except (ValueError, TypeError, KeyError, AttributeError):
        raise state_error(f"Invalid or out-of-bound Last.fm page {page}.") from None


def album_index(queue):
    records = {}
    with queue.lib.transaction():
        for album in queue.lib.albums():
            items = list(album.items())
            records[album.id] = {
                "added": epoch(album.get("added")),
                "first": epoch(album.get(FIELD)),
                "names": {
                    (
                        normalize(model.get("albumartist") or model.get("artist")),
                        normalize(album.album),
                    )
                    for model in [album, *items]
                }
                | {(normalize(item.artist), normalize(album.album)) for item in items},
                "releases": {
                    str(model.get("mb_albumid")).casefold()
                    for model in [album, *items]
                    if model.get("mb_albumid")
                },
                "groups": {
                    str(model.get("mb_releasegroupid")).casefold()
                    for model in [album, *items]
                    if model.get("mb_releasegroupid")
                },
            }
    added = [row["added"] for row in records.values() if row["added"] is not None]
    if not added:
        raise ListenError(
            "configuration_invalid", "No album has a valid added date.", 78
        )
    return records, int(min(added))


def text(value):
    return str(value.get("#text", "")) if isinstance(value, dict) else str(value or "")


def scan(cache, records, credentials, *, offline=False):
    releases, groups, names = (defaultdict(set) for _ in range(3))
    for album_id, record in records.items():
        for index, values in (
            (releases, record["releases"]),
            (groups, record["groups"]),
            (names, record["names"]),
        ):
            for value in values:
                index[value].add(album_id)
    first, sources, methods = {}, {}, Counter()
    processed = skipped = cached_pages = received = 0
    page, total = 1, 1
    while page <= max(1, total):
        tracks, total, count, cached = cache.page(page, credentials, offline=offline)
        cached_pages += cached
        if page == 1:
            print(
                f"Cutoff: {cache.state['cutoff']}; bounded scrobbles: {count}; estimated pages: {total} (ceil(total / 200)).",
                file=sys.stderr,
            )
        for track in tracks:
            if track.get("@attr", {}).get("nowplaying") not in ("true", True):
                received += 1
            stamp = epoch(track.get("date", {}).get("uts"))
            if (
                track.get("@attr", {}).get("nowplaying") in ("true", True)
                or stamp is None
            ):
                skipped += 1
                continue
            artist, album = text(track.get("artist")), text(track.get("album"))
            processed += 1
            if not normalize(artist) or not normalize(album):
                skipped += 1
                continue
            album_data = track.get("album", {})
            mbid = (
                str(album_data.get("mbid") or "").casefold()
                if isinstance(album_data, dict)
                else ""
            )
            targets, method = releases.get(mbid, set()), "release"
            if not targets:
                targets, method = groups.get(mbid, set()), "release_group"
            if not targets:
                targets, method = (
                    names.get((normalize(artist), normalize(album)), set()),
                    "artist_album",
                )
            methods[method if targets else "unmatched"] += 1
            identity = (normalize(artist), normalize(album))
            source = sources.setdefault(
                identity,
                {"artist": artist, "album": album, "first": stamp, "matched": False},
            )
            source["first"] = min(source["first"], stamp)
            source["matched"] |= bool(targets)
            for album_id in targets:
                first[album_id] = min(first.get(album_id, stamp), stamp)
        page += 1
    if received != count:
        raise state_error("Cached scrobble count does not match the bounded total.")
    unmatched = [row for key, row in sorted(sources.items()) if not row["matched"]]
    planned = {
        album_id: int(stamp)
        for album_id, stamp in first.items()
        if records[album_id]["first"] is None or stamp < records[album_id]["first"]
    }
    return planned, {
        "cutoff": cache.state["cutoff"],
        "pages": max(1, total),
        "estimated_pages": total,
        "cached_pages": cached_pages,
        "fetched_pages": max(1, total) - cached_pages,
        "scrobbles": processed,
        "skipped_entries": skipped,
        "source_albums": len(sources),
        "matched_albums": len(sources) - len(unmatched),
        "unmatched_albums": len(unmatched),
        "target_albums": len(first),
        "planned_updates": len(planned),
        "matching_methods": dict(methods),
        "unmatched_sample": [
            {
                "artist": row["artist"],
                "album": row["album"],
                "first_played": int(row["first"]),
            }
            for row in unmatched[:20]
        ],
    }


def report(data, *, stream=None):
    stream = sys.stdout if stream is None else stream
    print(
        f"{data['pages']} pages ({data['cached_pages']} cached, {data['fetched_pages']} fetched); "
        f"{data['scrobbles']} scrobbles; {data['matched_albums']} matched albums; "
        f"{data['unmatched_albums']} unmatched albums; {data['planned_updates']} updates.",
        file=stream,
    )
    for row in data["unmatched_sample"]:
        print(f"Unmatched: {row['artist']} — {row['album']}", file=stream)


def backfill(args, config, state, lock):
    queue = Queue(config, state, read_only=True)
    try:
        records, cutoff = album_index(queue)
        library_path = queue.lib.path
    finally:
        queue.close()
    root = Path(args.cache_dir or Path(state) / "lastfm-first-played")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    credentials = args.credentials_file or os.environ.get("LISTEN_LASTFM_CREDENTIALS")
    with shared_lock(root / ".lock", 5, message="First-played cache is busy."):
        cache = Cache(root, library_path, cutoff)
        planned, result = scan(cache, records, credentials)
        report(result, stream=sys.stderr)
        if args.apply:
            with shared_lock(lock, timeout_setting("LISTEN_BEETS_LOCK_TIMEOUT", 30)):
                queue = Queue(config, state, read_only=False)
                try:
                    current, current_cutoff = album_index(queue)
                    if (
                        current_cutoff != cutoff
                        or os.path.realpath(queue.lib.path) != cache.state["library"]
                    ):
                        raise state_error("The library cutoff changed during the scan.")
                    # Resolve against fresh albums, preserving concurrent earlier values.
                    planned, refreshed = scan(cache, current, None, offline=True)
                    refreshed.update(
                        cached_pages=result["cached_pages"],
                        fetched_pages=result["fetched_pages"],
                    )
                    result = refreshed
                    report(result, stream=sys.stderr)
                    with queue.lib.transaction():
                        for album_id, stamp in planned.items():
                            album = queue.lib.get_album(album_id)
                            album[FIELD] = stamp
                            album.store(inherit=False)
                finally:
                    queue.close()
        result["applied"] = args.apply
        return result

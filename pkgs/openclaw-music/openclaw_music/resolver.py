from __future__ import annotations

import http.client
import json
import threading
import time
from urllib.parse import quote, urlencode, urljoin, urlparse

from .deadline import DeadlineExpired, absolute_deadline, closing_create_connection
from .errors import BackendPermanent, BackendTransient, Configuration, Temporary

MAX_PAGES = 10
PAGE_SIZE = 100
HTTP_DEADLINE = 15.0
MIN_REQUEST_INTERVAL = 1.5


class MinimumRequestInterval:
    def __init__(
        self, interval: float = MIN_REQUEST_INTERVAL, *, clock=None, sleep=None
    ):
        self.interval = interval
        self.clock = clock or time.monotonic
        self.sleep = sleep or time.sleep
        self._lock = threading.Lock()
        self._last: float | None = None

    def wait(self) -> None:
        with self._lock:
            current = self.clock()
            if self._last is None:
                self._last = current
                return
            remaining = self.interval - (current - self._last)
            if remaining > 0:
                self.sleep(remaining)
            self._last = self.clock()


class MusicBrainzClient:
    def __init__(
        self,
        user_agent: str,
        base_url: str = "https://musicbrainz.org/ws/2",
        transport=None,
        limiter=None,
        *,
        deadline: float = HTTP_DEADLINE,
    ):
        parsed = urlparse(base_url)
        if (
            not user_agent
            or any(char in user_agent for char in "\r\n")
            or parsed.scheme != "https"
            or not parsed.hostname
            or parsed.params
            or parsed.query
            or parsed.fragment
        ):
            raise Configuration("invalid MusicBrainz configuration")
        self.base_url = base_url.rstrip("/")
        self.origin = (parsed.scheme, parsed.hostname.casefold(), parsed.port)
        self.base_path = parsed.path.rstrip("/")
        self.user_agent = user_agent
        self.transport = transport or self._transport
        self.limiter = limiter or MinimumRequestInterval()
        self.deadline = deadline

    def _transport(self, path: str) -> dict:
        url = urljoin(self.base_url + "/", path.lstrip("/"))
        parsed = urlparse(url)
        if (
            parsed.scheme,
            parsed.hostname.casefold() if parsed.hostname else "",
            parsed.port,
        ) != self.origin or not parsed.path.startswith(self.base_path + "/"):
            raise BackendPermanent("cross-origin MusicBrainz request refused")
        connection = None
        response = None
        try:
            with absolute_deadline(self.deadline):
                started = time.monotonic()
                connection = http.client.HTTPSConnection(
                    parsed.hostname, parsed.port, timeout=self._remaining(started)
                )
                connection._create_connection = closing_create_connection
                request_path = parsed.path + (
                    ("?" + parsed.query) if parsed.query else ""
                )
                connection.request(
                    "GET",
                    request_path,
                    headers={
                        "User-Agent": self.user_agent,
                        "Accept": "application/json",
                    },
                )
                response = connection.getresponse()
                if 300 <= response.status < 400:
                    raise BackendPermanent("MusicBrainz redirect refused")
                if 400 <= response.status < 500:
                    raise BackendPermanent(
                        f"MusicBrainz rejected request ({response.status})"
                    )
                if response.status >= 500:
                    category = self._endpoint_category(parsed.path)
                    if response.status == 503:
                        detail = {"endpoint": category}
                        retry_after = self._retry_after(
                            response.getheader("Retry-After")
                        )
                        if retry_after is not None:
                            detail["retry_after_seconds"] = retry_after
                        raise BackendTransient(
                            "MusicBrainz temporarily unavailable or throttled (503)",
                            detail=detail,
                        )
                    raise BackendTransient(
                        f"MusicBrainz temporary HTTP failure ({response.status})",
                        detail={"endpoint": category},
                    )
                chunks = []
                size = 0
                while True:
                    chunk = response.read(min(65_536, 2_000_001 - size))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    size += len(chunk)
                    if size > 2_000_000:
                        raise Temporary("MusicBrainz response too large")
                raw = b"".join(chunks)
                result = json.loads(raw)
                if not isinstance(result, dict):
                    raise Temporary("MusicBrainz returned invalid JSON")
                return result
        except (Temporary, BackendPermanent):
            raise
        except (
            DeadlineExpired,
            http.client.HTTPException,
            TimeoutError,
            OSError,
        ) as exc:
            raise BackendTransient("MusicBrainz unavailable") from exc
        finally:
            if response is not None:
                try:
                    response.close()
                except OSError:
                    pass
            if connection is not None:
                connection.close()

    def _remaining(self, started: float) -> float:
        remaining = self.deadline - (time.monotonic() - started)
        if remaining <= 0:
            raise TimeoutError("MusicBrainz deadline exceeded")
        return remaining

    @staticmethod
    def _endpoint_category(path: str) -> str:
        for endpoint in ("artist", "release-group", "release"):
            if path.rstrip("/").endswith("/" + endpoint):
                return endpoint
        return "release"

    @staticmethod
    def _retry_after(value: object) -> int | None:
        if not isinstance(value, str) or not value.isascii() or not value.isdecimal():
            return None
        seconds = int(value)
        return seconds if seconds <= 86_400 else None

    def get(self, path: str) -> dict:
        self.limiter.wait()
        result = self.transport(path)
        if not isinstance(result, dict):
            raise Temporary("MusicBrainz returned invalid JSON")
        return result

    def _pages(
        self, endpoint: str, key: str, count_keys: tuple[str, ...], query: dict
    ) -> list[dict]:
        output = []
        offset = 0
        for page in range(MAX_PAGES):
            args = {**query, "fmt": "json", "limit": PAGE_SIZE, "offset": offset}
            payload = self.get(endpoint + "?" + urlencode(args))
            values = payload.get(key)
            if not isinstance(values, list):
                raise Temporary("MusicBrainz pagination response is invalid")
            output.extend(value for value in values if isinstance(value, dict))
            total = next(
                (
                    payload[name]
                    for name in count_keys
                    if type(payload.get(name)) is int
                ),
                None,
            )
            if type(total) is int and total > MAX_PAGES * PAGE_SIZE:
                raise BackendPermanent(
                    "MusicBrainz result set exceeds safe pagination cap"
                )
            if total is None and len(values) < PAGE_SIZE:
                return output
            if not values:
                raise BackendPermanent("MusicBrainz pagination made no progress")
            offset += len(values)
            if type(total) is int and offset >= total:
                return output
        raise BackendPermanent("MusicBrainz pagination was truncated")

    @staticmethod
    def _literal(value: str) -> str:
        return value.replace("\\", "\\\\").replace('"', '\\"')

    def artists(self, artist: str) -> list[dict]:
        return self._pages(
            "/artist/",
            "artists",
            ("artist-count", "count"),
            {"query": f'artist:"{self._literal(artist)}"'},
        )

    def release_groups(self, artist_id: str) -> list[dict]:
        return self._pages(
            "/release-group/",
            "release-groups",
            ("release-group-count", "count"),
            {"artist": artist_id},
        )

    def releases(self, group_id: str) -> list[dict]:
        return self._pages(
            "/release/",
            "releases",
            ("release-count", "count"),
            {"release-group": group_id, "inc": "media"},
        )

    def release(self, release_id: str) -> dict:
        return self.get(
            "/release/"
            + quote(release_id, safe="")
            + "?"
            + urlencode({"fmt": "json", "inc": "media+recordings+artists"})
        )


def _date_parts(value: object) -> tuple[int, int | None, int | None] | None:
    if not isinstance(value, str):
        return None
    pieces = value.split("-")
    try:
        if len(pieces) not in {1, 2, 3} or not all(piece.isdigit() for piece in pieces):
            return None
        year = int(pieces[0])
        month = int(pieces[1]) if len(pieces) > 1 else None
        day = int(pieces[2]) if len(pieces) > 2 else None
        if month is not None and not 1 <= month <= 12:
            return None
        if day is not None and (month is None or not 1 <= day <= 31):
            return None
        return year, month, day
    except ValueError:
        return None


def _not_future(value: object, as_of: str) -> bool:
    interval = _date_interval(value)
    cutoff = _date_interval(as_of[:10])
    if interval is None or cutoff is None:
        return False
    return interval[0] <= cutoff[1]


def _date_interval(
    value: object,
) -> tuple[tuple[int, int, int], tuple[int, int, int]] | None:
    parts = _date_parts(value)
    if parts is None:
        return None
    year, month, day = parts
    if month is None:
        return (year, 1, 1), (year, 12, 31)
    if day is None:
        return (year, month, 1), (year, month, 31)
    return (year, month, day), (year, month, day)


def latest_groups(
    groups: list[dict], *, as_of: str, include_live: bool, include_compilations: bool
) -> list[dict]:
    eligible = []
    for group in groups:
        types = {str(value).casefold() for value in group.get("secondary-types", [])}
        if group.get("primary-type") != "Album":
            continue
        if (
            "live" in types
            and not include_live
            or "compilation" in types
            and not include_compilations
        ):
            continue
        if _not_future(group.get("first-release-date"), as_of):
            eligible.append(group)
    if not eligible:
        return []
    newest_lower = max(
        _date_interval(item["first-release-date"])[0] for item in eligible
    )
    return [
        item
        for item in eligible
        if _date_interval(item["first-release-date"])[1] >= newest_lower
    ]


def _artist_matches(item: dict, requested: str) -> bool:
    wanted = requested.casefold()
    if str(item.get("name", "")).casefold() == wanted:
        return True
    aliases = item.get("aliases", [])
    return isinstance(aliases, list) and any(
        isinstance(alias, dict) and str(alias.get("name", "")).casefold() == wanted
        for alias in aliases
    )


def _similar(value: object, requested: str) -> bool:
    candidate = "".join(char for char in str(value).casefold() if char.isalnum())
    wanted = "".join(char for char in requested.casefold() if char.isalnum())
    return bool(candidate and wanted and (candidate in wanted or wanted in candidate))


def _manifest(release: dict) -> list[dict]:
    manifest = []
    media = release.get("media")
    if not isinstance(media, list):
        return []
    for medium in media:
        if (
            not isinstance(medium, dict)
            or type(medium.get("position")) is not int
            or not isinstance(medium.get("format"), str)
        ):
            return []
        tracks = medium.get("tracks")
        if not isinstance(tracks, list) or not tracks:
            return []
        for track in tracks:
            recording = track.get("recording") if isinstance(track, dict) else None
            if (
                not isinstance(track, dict)
                or type(track.get("position")) is not int
                or not isinstance(track.get("number"), str)
            ):
                return []
            if (
                not isinstance(track.get("title"), str)
                or not track["title"].strip()
                or not isinstance(recording, dict)
                or not isinstance(recording.get("id"), str)
            ):
                return []
            length = recording.get("length", track.get("length"))
            if type(length) is not int or length <= 0:
                return []
            manifest.append(
                {
                    "disc": medium["position"],
                    "format": medium["format"],
                    "track": track["position"],
                    "number": track["number"],
                    "title": track["title"],
                    "recording_mbid": recording["id"],
                    "duration_ms": length,
                }
            )
    return manifest


class Resolver:
    def __init__(self, client: MusicBrainzClient):
        self.client = client

    @staticmethod
    def _choice(stage: str, items: list[dict]) -> dict:
        return {"state": "needs_choice", "stage": stage, "candidates": items}

    def resolve(self, request: dict, selections: dict | None, as_of: str) -> dict:
        selections = selections or {}
        chosen = selections.get("artist")
        if chosen:
            if (
                not isinstance(chosen, dict)
                or not isinstance(chosen.get("id"), str)
                or not chosen["id"]
            ):
                raise BackendPermanent("persisted artist selection is invalid")
            artist_results = []
            artists = [chosen]
        else:
            artist_results = self.client.artists(request["artist"])
            artists = [
                item
                for item in artist_results
                if _artist_matches(item, request["artist"])
            ]
        if len(artists) != 1:
            alternatives = (
                artists
                or [
                    item
                    for item in artist_results
                    if _similar(item.get("name"), request["artist"])
                ]
                or artist_results
            )
            return self._choice(
                "artist",
                [
                    {
                        "label": item.get("name", "unknown"),
                        "reason": "artist ambiguity",
                        "entity": item,
                    }
                    for item in alternatives[:20]
                ],
            )
        groups = self.client.release_groups(artists[0]["id"])
        chosen_group = selections.get("release_group")
        if chosen_group:
            if (
                not isinstance(chosen_group, dict)
                or not isinstance(chosen_group.get("id"), str)
                or not chosen_group["id"]
            ):
                raise BackendPermanent("persisted release-group selection is invalid")
            canonical = [
                group for group in groups if group.get("id") == chosen_group["id"]
            ]
            if len(canonical) != 1:
                raise BackendPermanent(
                    "persisted release-group is not in the selected artist catalog"
                )
            groups = canonical
            chosen_group = canonical[0]
        requested = request["release"].casefold()
        release_cache = {}
        if chosen_group:
            pass
        elif requested in {"latest", "new", "newest", "latest album", "new album"}:
            latest_pool = []
            for group in groups:
                types = {
                    str(value).casefold() for value in group.get("secondary-types", [])
                }
                if group.get("primary-type") != "Album":
                    continue
                if "live" in types and not request.get("include_live", False):
                    continue
                if "compilation" in types and not request.get(
                    "include_compilations", False
                ):
                    continue
                if _not_future(group.get("first-release-date"), as_of):
                    latest_pool.append(group)
            latest_pool.sort(
                key=lambda item: _date_interval(item["first-release-date"])[0],
                reverse=True,
            )
            if len(latest_pool) > 20:
                raise BackendPermanent(
                    "too many latest release groups to verify safely"
                )
            eligible_groups = []
            for group in latest_pool:
                releases = [
                    item
                    for item in self.client.releases(group["id"])
                    if item.get("status") == "Official"
                    and _not_future(item.get("date"), as_of)
                ]
                if releases:
                    eligible_groups.append(group)
                    release_cache[group["id"]] = releases
            if eligible_groups:
                newest_lower = max(
                    _date_interval(group["first-release-date"])[0]
                    for group in eligible_groups
                )
                groups = [
                    group
                    for group in eligible_groups
                    if _date_interval(group["first-release-date"])[1] >= newest_lower
                ]
            else:
                groups = []
        else:
            all_groups = groups
            exact_groups = [
                item
                for item in all_groups
                if str(item.get("title", "")).casefold() == requested
            ]
            if exact_groups:
                groups = exact_groups
            else:
                alternatives = [
                    item
                    for item in all_groups
                    if _similar(item.get("title"), request["release"])
                ] or all_groups
                return self._choice(
                    "release_group",
                    [
                        {
                            "label": item.get("title", "unknown"),
                            "reason": "no exact title match",
                            "entity": item,
                        }
                        for item in alternatives[:20]
                    ],
                )
        if len(groups) != 1:
            return self._choice(
                "release_group",
                [
                    {
                        "label": item.get("title", "unknown"),
                        "reason": "release-group ambiguity",
                        "entity": item,
                    }
                    for item in groups
                ],
            )
        releases = release_cache.get(groups[0]["id"])
        if releases is None:
            releases = [
                item
                for item in self.client.releases(groups[0]["id"])
                if item.get("status") == "Official"
                and _not_future(item.get("date"), as_of)
            ]
        edition = request.get("edition")
        if edition:

            def edition_evidence(item: dict) -> str:
                media = " ".join(
                    str(medium.get("format", ""))
                    for medium in item.get("media", [])
                    if isinstance(medium, dict)
                )
                return (
                    " ".join(
                        str(item.get(name, ""))
                        for name in ("title", "country", "date", "disambiguation")
                    )
                    + " "
                    + media
                )

            releases = [
                item
                for item in releases
                if edition.casefold() in edition_evidence(item).casefold()
            ]
        if request.get("medium"):
            releases = [
                item
                for item in releases
                if any(
                    str(medium.get("format", "")).casefold()
                    == request["medium"].casefold()
                    for medium in item.get("media", [])
                )
            ]
        chosen = selections.get("edition")
        if chosen:
            releases = [item for item in releases if item.get("id") == chosen.get("id")]
        if len(releases) != 1:
            return self._choice(
                "edition",
                [
                    {
                        "label": item.get("title", "unknown"),
                        "reason": "edition ambiguity",
                        "entity": item,
                        "date": item.get("date"),
                        "country": item.get("country"),
                        "status": item.get("status"),
                        "disambiguation": item.get("disambiguation"),
                        "media": [
                            medium.get("format")
                            for medium in item.get("media", [])
                            if isinstance(medium, dict)
                        ],
                        "track_count": sum(
                            len(medium.get("tracks", []))
                            for medium in item.get("media", [])
                            if isinstance(medium, dict)
                        ),
                    }
                    for item in releases
                ],
            )
        exact = self.client.release(releases[0]["id"])
        if exact.get("id") != releases[0]["id"] or exact.get("status") != "Official":
            raise BackendPermanent("MusicBrainz release detail is inconsistent")
        tracks = _manifest(exact)
        if not tracks:
            raise BackendPermanent("MusicBrainz release has no safe track manifest")
        return {
            "state": "resolved",
            "resolved_release": {
                "mbid": exact["id"],
                "title": exact.get("title"),
                "artist": request["artist"],
                "tracks": tracks,
                "search_text": request["artist"]
                + " "
                + str(exact.get("title", request["release"])),
                "details": exact,
            },
        }

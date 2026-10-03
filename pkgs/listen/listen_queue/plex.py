"""Read-only Plex discovery and conservative album matching."""

import re
from dataclasses import dataclass, field

from .errors import ListenError
from .library import normalize, now_stamp

MBID = re.compile(
    r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)


@dataclass
class PlexAlbum:
    id: str
    albumartist: str
    album: str
    release_ids: set = field(default_factory=set)
    group_ids: set = field(default_factory=set)
    guids: set = field(default_factory=set)
    track_ids: set = field(default_factory=set)

    def metadata(self):
        return {"id": self.id, "albumartist": self.albumartist, "album": self.album}


def guid_values(item):
    values = {str(g.id) for g in getattr(item, "guids", []) or []}
    if getattr(item, "guid", None):
        values.add(str(item.guid))
    return values


def musicbrainz_ids(guids):
    releases, groups = set(), set()
    for guid in guids:
        lower = guid.casefold()
        if not ("musicbrainz" in lower or lower.startswith("mbid://")):
            continue
        ids = {value.lower() for value in MBID.findall(guid)}
        (
            groups if "release-group" in lower or "releasegroup" in lower else releases
        ).update(ids)
    return releases, groups


def discover(plex):
    containers = []
    needle = "albums i should listen to"
    for playlist in plex.playlists(playlistType="audio"):
        if needle in normalize(playlist.title):
            containers.append(("playlist", playlist))
    for section in plex.library.sections():
        if section.type == "artist":
            for collection in section.collections():
                if needle in normalize(collection.title):
                    containers.append(("collection", collection))
    if not containers:
        raise ListenError(
            "not_found", "No Plex listen collection or playlist was found.", 65
        )
    sources, albums, unsupported = [], {}, []
    for kind, container in containers:
        sources.append(
            {"kind": kind, "id": str(container.ratingKey), "title": container.title}
        )
        for entry in container.items():
            if entry.type == "track":
                model = entry.album()
            elif entry.type == "album":
                model = entry
            else:
                unsupported.append(
                    {
                        "plex_album": {
                            "id": str(entry.ratingKey),
                            "albumartist": "",
                            "album": entry.title,
                        },
                        "reason": "unsupported_item",
                        "candidates": [],
                    }
                )
                continue
            key = str(model.ratingKey)
            if key not in albums:
                guids = guid_values(model)
                releases, groups = musicbrainz_ids(guids)
                album = PlexAlbum(
                    key, model.parentTitle or "", model.title, releases, groups, guids
                )
                # Existing plexsync identifiers are stored on beets tracks.
                # Include every track, including when the source is album-only.
                for track in model.tracks():
                    album.track_ids.add(str(track.ratingKey))
                    album.guids.update(guid_values(track))
                albums[key] = album
    return sources, list(albums.values()), unsupported


def connect():
    from plexapi.myplex import MyPlexAccount

    return MyPlexAccount(timeout=10).resource("alexandria").connect(timeout=10)


def library_identifiers(album):
    items = list(album.items())
    values = [album, *items]
    return {
        "mb_albumid": {
            str(v.get("mb_albumid")).casefold() for v in values if v.get("mb_albumid")
        },
        "mb_releasegroupid": {
            str(v.get("mb_releasegroupid")).casefold()
            for v in values
            if v.get("mb_releasegroupid")
        },
        "plex_guid": {str(v.get("plex_guid")) for v in values if v.get("plex_guid")},
        "plex_ratingkey": {
            str(v.get("plex_ratingkey")) for v in values if v.get("plex_ratingkey")
        },
    }


def match(plex_album, albums, identifiers):
    checks = (
        ("mb_albumid", plex_album.release_ids),
        ("mb_releasegroupid", plex_album.group_ids),
        ("plex_guid", plex_album.guids),
        ("plex_ratingkey", plex_album.track_ids | {plex_album.id}),
    )
    for method, values in checks:
        candidates = [a for a in albums if values & identifiers[a.id][method]]
        if candidates:
            return candidates, method
    key = (normalize(plex_album.albumartist), normalize(plex_album.album))
    candidates = [
        a for a in albums if (normalize(a.albumartist), normalize(a.album)) == key
    ]
    return candidates, "albumartist_album"


def seed(queue, apply=False, plex=None):
    receipt = queue.state.read("plex-seed.json")
    if apply and receipt:
        raise ListenError("already_seeded", "Plex seeding has already been applied.")
    try:
        sources, plex_albums, unmatched = discover(
            plex if plex is not None else connect()
        )
    except ListenError:
        raise
    except Exception as exc:
        # Plex exceptions may include URLs/tokens; keep them out of both outputs.
        raise ListenError(
            "backend_unavailable",
            "Plex discovery failed; check its configuration and connection.",
            75,
        ) from exc
    albums = list(queue.lib.albums())
    identifiers = {album.id: library_identifiers(album) for album in albums}
    matched, queued = [], {}
    for plex_album in plex_albums:
        candidates, method = match(plex_album, albums, identifiers)
        if len(candidates) == 1:
            album = candidates[0]
            queued[album.id] = album
            matched.append(
                {
                    "plex_album": plex_album.metadata(),
                    "album": queue.metadata(album),
                    "method": method,
                }
            )
        else:
            unmatched.append(
                {
                    "plex_album": plex_album.metadata(),
                    "reason": "ambiguous" if candidates else "not_found",
                    "candidates": [queue.metadata(a) for a in candidates],
                }
            )
    if apply:
        with queue.lib.transaction():
            for album in queued.values():
                album["listen_state"] = "queued"
                album.store(inherit=False)
        queue.state.write(
            "plex-seed.json",
            applied_at=now_stamp(),
            sources=sources,
            queued_ids=sorted(queued),
        )
        for result in matched:
            result["album"] = queue.metadata(queued[result["album"]["id"]])
    return {
        "applied": apply,
        "already_seeded": bool(receipt),
        "sources": sources,
        "matched": matched,
        "unmatched": unmatched,
        "queued_ids": sorted(queued) if apply else [],
    }

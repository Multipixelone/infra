"""Read-only Plex discovery and conservative album matching."""

import os
import re
from dataclasses import dataclass, field
from datetime import datetime, timezone

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


def configured_sources():
    sources = {}
    for state, variable in (
        ("queued", "LISTEN_PLEX_SOURCE"),
        ("listened", "LISTEN_PLEX_DONE_SOURCE"),
    ):
        title = os.environ.get(variable, "")
        if not normalize(title):
            raise ListenError(
                "configuration_invalid",
                f"Set {variable} to an exact Plex source title.",
                78,
            )
        sources[state] = title
    if normalize(sources["queued"]) == normalize(sources["listened"]):
        raise ListenError(
            "configuration_invalid",
            "Plex queue and done source titles must differ.",
            78,
        )
    return sources


def discover(plex, title):
    containers = []
    needle = normalize(title)
    for playlist in plex.playlists(playlistType="audio"):
        if needle == normalize(playlist.title):
            containers.append(("playlist", playlist))
    for section in plex.library.sections():
        if section.type == "artist":
            for collection in section.collections():
                if needle == normalize(collection.title):
                    containers.append(("collection", collection))
    if not containers:
        raise ListenError(
            "not_found",
            "No Plex collection or playlist matched the configured title.",
            65,
            title=title,
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


def plan_matches(queue, plex=None):
    """Discover both sources and match them without changing library or state."""
    titles = configured_sources()
    discovered = {}
    try:
        server = plex if plex is not None else connect()
        # Resolve both sources before matching or mutating anything.
        for state, title in titles.items():
            discovered[state] = discover(server, title)
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
    groups, updates = {}, {}
    for state, (sources, plex_albums, unmatched) in discovered.items():
        matched, selected = [], {}
        for plex_album in plex_albums:
            candidates, method = match(plex_album, albums, identifiers)
            if len(candidates) == 1:
                album = candidates[0]
                selected[album.id] = album
                matched.append(
                    {
                        "plex_album": plex_album.metadata(),
                        "album": queue.metadata(album),
                        "method": method,
                        "target_state": state,
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
        for result in unmatched:
            result["target_state"] = state
        updates[state] = selected
        groups[state] = {
            "sources": [dict(source, target_state=state) for source in sources],
            "matched": matched,
            "unmatched": unmatched,
        }
    overlap = sorted(updates["queued"].keys() & updates["listened"].keys())
    for album_id in overlap:
        del updates["queued"][album_id]
    for state, group in groups.items():
        group["planned_ids"] = sorted(updates[state])
        group["counts"] = {
            "matched": len(group["matched"]),
            "unmatched": len(group["unmatched"]),
            "ambiguous": sum(r["reason"] == "ambiguous" for r in group["unmatched"]),
            "planned": len(updates[state]),
        }
        for result in group["matched"]:
            result["effective_state"] = (
                "listened" if result["album"]["id"] in updates["listened"] else "queued"
            )
    return groups, updates, overlap


def seed(queue, apply=False, plex=None):
    receipt = queue.state.read("plex-seed.json")
    if apply and receipt:
        raise ListenError("already_seeded", "Plex seeding has already been applied.")
    groups, updates, overlap = plan_matches(queue, plex)
    if apply:
        pick = queue.state.read("last-pick.json")
        listened_at = datetime.now(timezone.utc).timestamp()
        with queue.lib.transaction():
            for state, selected in updates.items():
                for album in selected.values():
                    album["listen_state"] = state
                    if state == "listened":
                        album["listened_at"] = listened_at
                    album.store(inherit=False)
        if pick and pick.get("album_id") in updates["listened"]:
            queue.state.clear_pick()
        queue.state.write(
            "plex-seed.json",
            applied_at=now_stamp(),
            sources=[
                source for group in groups.values() for source in group["sources"]
            ],
            queued_ids=sorted(updates["queued"]),
            listened_ids=sorted(updates["listened"]),
        )
        for group in groups.values():
            for result in group["matched"]:
                album = updates[result["effective_state"]][result["album"]["id"]]
                result["album"] = queue.metadata(album)
    return {
        "applied": apply,
        "already_seeded": bool(receipt),
        "groups": groups,
        "sources": [source for group in groups.values() for source in group["sources"]],
        "matched": [result for group in groups.values() for result in group["matched"]],
        "unmatched": [
            result for group in groups.values() for result in group["unmatched"]
        ],
        "overlap_ids": overlap,
        "queued_ids": sorted(updates["queued"]) if apply else [],
        "listened_ids": sorted(updates["listened"]) if apply else [],
    }


def sync(queue, apply=False, plex=None):
    """Import only unmarked albums; existing listen decisions always win."""
    groups, updates, overlap = plan_matches(queue, plex)
    for state, group in groups.items():
        skipped = set()
        for result in group["matched"]:
            album_id = result["album"]["id"]
            existing = result["album"]["listen_state"]
            result["skipped"] = bool(existing)
            if existing:
                result["reason"] = "existing_state"
                result["effective_state"] = existing
                skipped.add(album_id)
                updates[state].pop(album_id, None)
        group["skipped_ids"] = sorted(skipped)
        group["planned_ids"] = sorted(updates[state])
        group["counts"].update(skipped=len(skipped), planned=len(updates[state]))
    # Report precedence only for new albums; existing decisions are preserved.
    overlap = [album_id for album_id in overlap if album_id in updates["listened"]]
    if apply:
        listened_at = datetime.now(timezone.utc).timestamp()
        with queue.lib.transaction():
            for state, selected in updates.items():
                for album in selected.values():
                    album["listen_state"] = state
                    if state == "listened":
                        album["listened_at"] = listened_at
                    album.store(inherit=False)
        for group in groups.values():
            for result in group["matched"]:
                if not result["skipped"]:
                    album = updates[result["effective_state"]][result["album"]["id"]]
                    result["album"] = queue.metadata(album)
    return {
        "applied": apply,
        "groups": groups,
        "sources": [source for group in groups.values() for source in group["sources"]],
        "matched": [result for group in groups.values() for result in group["matched"]],
        "unmatched": [
            result for group in groups.values() for result in group["unmatched"]
        ],
        "overlap_ids": overlap,
        "queued_ids": sorted(updates["queued"]) if apply else [],
        "listened_ids": sorted(updates["listened"]) if apply else [],
    }

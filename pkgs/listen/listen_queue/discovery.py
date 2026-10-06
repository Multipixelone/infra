"""Combine independent preferences, rank a library, and sample queue picks."""

import copy
import math
import random
import statistics
from datetime import datetime, timezone

from .errors import ListenError, invalid
from .graph import Graph, TextClient, decode_vector
from .library import normalize, number
from .selection import cap_for, filter_reasons, filters_for

METADATA = ("artist", "genre", "label", "rosamerica")
REPEATABLE = (
    *METADATA,
    "mood",
    "avoid-mood",
    "vibe",
    "more-like",
    "more-like-id",
    "descriptor",
    "danceability",
    "vocal",
)
GRAPH_INPUTS = {
    "vibe",
    "more-like",
    "more-like-id",
    "descriptor",
    "danceability",
    "vocal",
}


def percentiles(values):
    """Midrank/(n-1), calibrated before queue, cap, or hard-input filtering."""
    observed = sorted(
        (value, identity) for identity, value in values.items() if value is not None
    )
    result = {identity: 0.5 for identity in values}
    if len(observed) < 2:
        return result
    start = 0
    while start < len(observed):
        end = start + 1
        while end < len(observed) and observed[end][0] == observed[start][0]:
            end += 1
        value = (start + end - 1) / (2 * (len(observed) - 1))
        for _, identity in observed[start:end]:
            result[identity] = value
        start = end
    return result


def history_score(album, mode, now):
    plays = album["plays_per_track"] or 0
    if mode == "fresh":
        return 1 / (1 + plays), plays <= 1
    stamp = album["listened_at"]
    age = (
        max(
            0,
            (now - datetime.fromisoformat(stamp.replace("Z", "+00:00"))).total_seconds()
            / 86400,
        )
        if stamp
        else None
    )
    familiarity = math.log1p(plays) / (1 + math.log1p(plays))
    return (
        familiarity * min(1, age / 90) if age is not None else 0,
        plays > 0 and age is not None and age >= 90,
    )


def parse_inputs(args, names):
    inputs = []
    for kind in REPEATABLE:
        inputs.extend(
            (kind, value, False) for value in getattr(args, kind.replace("-", "_"))
        )
    for kind in ("relaxed", "instrumental"):
        if getattr(args, kind):
            inputs.append(("mood", kind, False))
    for kind in ("fresh", "rediscover"):
        if getattr(args, kind):
            inputs.append((kind, None, False))
    for text in args.require:
        kind, separator, value = text.partition("=")
        if kind in ("relaxed", "instrumental") and not separator:
            inputs.append(("mood", kind, True))
        elif kind in ("fresh", "rediscover") and not separator:
            inputs.append((kind, None, True))
        elif kind in REPEATABLE and separator:
            inputs.append((kind, value, True))
        else:
            raise invalid(
                "--require needs a supported KIND=VALUE or relaxed/instrumental/fresh/rediscover."
            )
    canonical = {}
    for kind, value, hard in inputs:
        if kind not in ("fresh", "rediscover"):
            value = str(value).strip()
            if not value:
                raise invalid("Preference text must not be empty.")
        if kind == "descriptor" and value.startswith("xtractor:"):
            kind, value = "mood", value.removeprefix("xtractor:")
        if kind in ("mood", "avoid-mood") and value not in names:
            raise invalid("Unknown mood; use listen moods to list available names.")
        if kind == "vibe" and (len(value) > 240 or len(value.encode("utf-8")) > 4000):
            raise invalid(
                "Vibe phrases must be 1–240 characters and fit a 4 KiB request."
            )
        if kind == "more-like-id":
            try:
                value = int(value)
                if value <= 0:
                    raise ValueError()
            except ValueError:
                raise invalid("more-like-id requires a positive album ID.") from None
        elif kind == "danceability":
            low, separator, high = value.partition(":")
            low, high = number(low, score=True), number(high, score=True)
            if not separator or low is None or high is None or low > high:
                raise invalid("Danceability needs inclusive MIN:MAX in [0,1].")
            value = (low, high)
        elif kind == "vocal" and value not in ("vocal", "instrumental"):
            raise invalid("Vocal preference must be vocal or instrumental.")
        key = (kind, value)
        canonical[key] = canonical.get(key, False) or hard
    kinds = {kind for kind, _ in canonical}
    if {"fresh", "rediscover"} <= kinds:
        raise invalid(
            "--fresh and --rediscover are mutually exclusive, including required inputs."
        )
    favored = {value for kind, value in canonical if kind == "mood"}
    avoided = {value for kind, value in canonical if kind == "avoid-mood"}
    if favored & avoided:
        raise invalid("A mood cannot be both favored and avoided.")
    return canonical


def literal_match(album, kind, terms):
    values = {
        "artist": [album["albumartist"]],
        "genre": album["genres"],
        "label": [album["label"] or ""],
        "rosamerica": [album["genre_rosamerica"]["genre"] or ""],
    }[kind]
    if kind == "rosamerica":
        return float(
            any(
                normalize(term) == normalize(value)
                for term in terms
                for value in values
            )
        )
    return float(
        any(normalize(term) in normalize(value) for term in terms for value in values)
    )


def components_for(inputs, graph, queue, albums, now):
    """Each component carries raw scores, comparable scores and hard matches."""
    # Resolve catalog aliases and album text before deduplicating inputs.
    resolved = {}
    references = set()
    reference_titles = {}
    for (kind, value), hard in inputs.items():
        if kind == "descriptor":
            value = graph.descriptor(value)
        elif kind in ("more-like", "more-like-id"):
            reference = queue.resolve(
                value if kind == "more-like" else None,
                value if kind == "more-like-id" else None,
            )
            kind, value = "more-like-id", reference.id
            references.add(value)
            reference_titles[value] = f"{reference.albumartist} — {reference.album}"
        key = (kind, value)
        resolved[key] = resolved.get(key, False) or hard
    # Preserve repeatable metadata alternatives as one soft component.
    grouped = [
        (kind, value, hard)
        for (kind, value), hard in resolved.items()
        if kind not in METADATA or hard
    ]
    for kind in METADATA:
        alternatives = tuple(
            value for (key, value), hard in resolved.items() if key == kind and not hard
        )
        if alternatives:
            grouped.append((kind, alternatives, False))
    components = []
    client = (
        TextClient(graph.data["text_model_id"])
        if any(kind == "vibe" for kind, _, _ in grouped)
        else None
    )
    vector_cache = {}

    def vector(identity, key):
        cache_key = (identity, key)
        if cache_key not in vector_cache:
            row = graph.albums.get(identity)
            vector_cache[cache_key] = (
                decode_vector(
                    row[key], graph.data["vector_dimension"] if key == "vector" else 512
                )
                if row and row.get(key) is not None
                else None
            )
        return vector_cache[cache_key]

    for kind, value, hard in grouped:
        label = f"{kind}: {value}" if value is not None else kind
        raw, matches = {}, {}
        learned = kind in ("mood", "avoid-mood", "descriptor", "vibe", "more-like-id")
        extra = {}
        if kind in ("vibe", "more-like-id"):
            key = (
                "vector"
                if kind == "more-like-id"
                and graph.data["model_id"].startswith("style:")
                else "text_vector"
            )
            target = client.embed(value) if kind == "vibe" else vector(value, key)
            if target is None:
                raise ListenError(
                    "not_found",
                    "Reference album has no compatible embedding in the export.",
                    65,
                    album_id=value,
                )
            if kind == "more-like-id":
                label = f"like {reference_titles[value]}"
            extra["space"] = "style" if key == "vector" else "text"
        for album in albums:
            identity = album["id"]
            if kind in METADATA:
                score = literal_match(
                    album, kind, value if isinstance(value, tuple) else (value,)
                )
                match = score == 1
            elif kind in ("mood", "avoid-mood"):
                score = album["scores"][value]["score"]
                match = score is not None and (
                    score <= 0.5 if kind == "avoid-mood" else score >= 0.5
                )
            elif kind in ("fresh", "rediscover"):
                score, match = history_score(album, kind, now)
            elif kind == "descriptor":
                score = graph.score(value, identity)
                column = graph.catalog[value]
                threshold = (
                    0.5
                    if column["kind"] in ("relative", "zscore")
                    or column["source"] == "essentia"
                    else 0.05
                )
                match = score is not None and score >= threshold
            elif kind in ("vibe", "more-like-id"):
                candidate = vector(identity, key)
                score = (
                    max(-1, min(1, sum(a * b for a, b in zip(candidate, target))))
                    if candidate is not None
                    else None
                )
                match = (
                    score is not None and score >= 0.7
                )  # Vibe uses population z below.
            else:
                row = graph.albums.get(identity)
                field = (
                    row["essentia"].get(
                        "danceable" if kind == "danceability" else "voice_instrumental",
                        {},
                    )
                    if row
                    else {}
                )
                observed = field.get("value")
                if kind == "danceability":
                    observed = number(observed, score=True)
                    score = (
                        1 - max(value[0] - observed, observed - value[1], 0)
                        if observed is not None
                        else None
                    )
                    match = observed is not None and value[0] <= observed <= value[1]
                else:
                    score = float(observed == value) if observed is not None else None
                    match = score == 1
            raw[identity], matches[identity] = score, match
        normalized = (
            percentiles(raw)
            if learned
            else {
                identity: score if score is not None else 0.5
                for identity, score in raw.items()
            }
        )
        if kind == "avoid-mood":
            normalized = {identity: 1 - score for identity, score in normalized.items()}
        if kind == "vibe":
            observed = [score for score in raw.values() if score is not None]
            mean = statistics.fmean(observed) if observed else 0
            std = statistics.pstdev(observed) if observed else 0
            zscores = {
                identity: (score - mean) / std
                if score is not None and std > 1e-8
                else 0
                for identity, score in raw.items()
            }
            matches = {
                identity: raw[identity] is not None and score >= 0.5
                for identity, score in zscores.items()
            }
            extra["population_z"] = zscores
        components.append(
            {
                "kind": kind,
                "value": value,
                "hard": hard,
                "label": label,
                "raw": raw,
                "normalized": normalized,
                "matches": matches,
                **extra,
            }
        )
    return components, references


def ranked_sample(albums, count, rng):
    remaining, chosen = list(albums), []
    while remaining and len(chosen) < count:
        top = remaining[:5]
        album = rng.choices(top, weights=[1 + album["score"] for album in top])[0]
        chosen.append(album)
        remaining.remove(album)
    return chosen


def discover(queue, args, rng=None, now=None):
    inputs = parse_inputs(args, set(queue.fields))
    filter_args = copy.copy(args)
    filter_args.mood = [value for kind, value in inputs if kind == "mood"]
    filter_args.avoid_mood = [value for kind, value in inputs if kind == "avoid-mood"]
    filters = filters_for(filter_args, set(queue.fields))
    graph = Graph.read(required=any(kind in GRAPH_INPUTS for kind, _ in inputs))
    models = {model.id: model for model in queue.albums("all")}
    score_names = (
        set(filters["moods"] + filters["avoid_moods"])
        | filters["min_scores"].keys()
        | filters["max_scores"].keys()
    )
    history = any(kind in ("fresh", "rediscover") for kind, _ in inputs)
    needs_length = (
        args.command == "pick"
        or args.max_minutes is not None
        or args.min_minutes is not None
    )
    classifiers = bool(args.mirex_cluster) or any(
        kind == "rosamerica" for kind, _ in inputs
    )
    # Percentiles use the whole library, but compute only referenced classifiers.
    # Graph-only find needs no track queries until the final albums are selected.
    library = [
        queue.metadata(
            model,
            score_names=score_names,
            tracks=(needs_length or history)
            and (args.library or model.get("listen_state") == "queued"),
            play_history=history,
            bpm=args.bpm_min is not None or args.bpm_max is not None,
            classifiers=classifiers,
        )
        for model in models.values()
    ]
    components, references = components_for(
        inputs, graph, queue, library, now or datetime.now(timezone.utc)
    )
    cap = (
        cap_for(args.max_minutes)
        if args.command == "pick" or args.max_minutes is not None
        else None
    )
    albums = []
    unknown = []
    for album in library:
        identity = album["id"]
        if (
            args.command == "pick"
            and not args.library
            and album["listen_state"] != "queued"
        ) or identity in references:
            continue
        if any(
            component["kind"] in GRAPH_INPUTS and component["raw"][identity] is None
            for component in components
        ):
            continue
        length = album["length_seconds"]
        fits = length <= cap["minutes"] * 60 if cap and length is not None else None
        if needs_length and length is None:
            unknown.append(identity)
        reasons = filter_reasons(album, filters)
        if cap is not None and not fits:
            reasons.append("max-minutes")
        breakdown = []
        for component in components:
            if component["hard"] and not component["matches"][identity]:
                reasons.append("require:" + component["kind"])
            entry = {key: component[key] for key in ("kind", "value", "hard")}
            entry.update(
                raw=component["raw"][identity],
                normalized=component["normalized"][identity],
            )
            if "space" in component:
                entry["space"] = component["space"]
            if "population_z" in component:
                entry["population_z"] = component["population_z"][identity]
            breakdown.append(entry)
        score = (
            statistics.fmean(entry["normalized"] for entry in breakdown)
            if breakdown
            else 0.5
        )
        ranked = sorted(
            components, key=lambda component: -component["normalized"][identity]
        )
        why = [
            component["label"][:80]
            for component in ranked
            if component["raw"][identity] is not None
            and component["normalized"][identity] > 0
        ][:3]
        album.update(
            fits=fits,
            over_minutes=max(0, length / 60 - cap["minutes"])
            if cap and length is not None
            else None,
            matches_filters=not reasons,
            filter_reasons=sorted(set(reasons)),
            score=score,
            score_breakdown=breakdown,
            why=why,
        )
        albums.append(album)
    if not args.pool:
        albums = [album for album in albums if album["matches_filters"]]
        albums.sort(
            key=lambda album: (
                -album["score"],
                normalize(album["albumartist"]),
                normalize(album["album"]),
                album["id"],
            )
        )
        albums = (
            ranked_sample(albums, args.count, rng or random.SystemRandom())
            if args.command == "pick"
            else albums[: args.count]
        )
    for album in albums:
        full = queue.metadata(models[album["id"]])
        selection = {
            key: album[key]
            for key in (
                "fits",
                "over_minutes",
                "matches_filters",
                "filter_reasons",
                "score",
                "score_breakdown",
                "why",
            )
        }
        album.clear()
        album.update(full)
        album.update(selection)
        if graph is not None:
            album["album_graph"] = graph.details(album["id"])
    return {
        "mode": "pool" if args.pool else "suggestions",
        "cap": cap,
        "filters": filters,
        "requested_count": None if args.pool else args.count,
        "albums": albums,
        "unknown_length_ids": unknown,
        "album_graph": graph.metadata if graph is not None else None,
        "history": {
            "mode": next(
                (kind for kind, _ in inputs if kind in ("fresh", "rediscover")),
                "neutral",
            ),
            "recency_source": "listened_at",
            "recency_is_proxy": True,
            "rediscover_days": 90,
        },
    }

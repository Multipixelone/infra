"""Read schema-v3 album graphs and query their text encoder without beets locks.

Wire decoding follows beets-plugins/plugins/embed/beets_embed/sounds.py and
viewer/{logic,sound}.mjs. In particular, column byte zero means missing, while
vector bytes are signed and their per-album scale disappears under cosine.
"""

import base64
import binascii
import json
import math
import os
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from .errors import ListenError, invalid
from .library import normalize, number


def finite(value):
    return type(value) in (int, float) and number(value) is not None


def unpack(value):
    if not isinstance(value, str):
        raise TypeError("Expected base64 text")
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise ValueError("Invalid base64") from exc


def decode_vector(value, dimension):
    packed = unpack(value)
    if len(packed) != dimension or not packed or not any(packed):
        raise ValueError("Invalid vector dimension or zero vector")
    values = [byte if byte < 128 else byte - 256 for byte in packed]
    norm = math.sqrt(sum(value * value for value in values))
    return [value / norm for value in values]


def decode_column(column, count):
    packed = unpack(column["scores"])
    low, high = column["min"], column["max"]
    if len(packed) != count or not finite(low) or not finite(high) or low >= high:
        raise ValueError("Invalid descriptor score column")
    return [
        None if byte == 0 else low + (byte - 1) * (high - low) / 254 for byte in packed
    ]


class Graph:
    def __init__(self, data):
        if not isinstance(data, dict) or data.get("schema_version") != 3:
            raise ValueError("Expected schema-v3 album graph")
        self.data = data
        rows, labels, fields = data["albums"], data["labels"], data["essentia_fields"]
        if not isinstance(rows, list) or not isinstance(labels, list):
            raise TypeError("Invalid albums or label catalog")
        if (
            data["sound_encoding"] != "catalog-pairs-v1"
            or data["vector_encoding"] != "int8-base64"
            or type(data["vector_dimension"]) is not int
            or data["vector_dimension"] < 1
            or data["text_vector_encoding"] != "int8-base64"
            or data["text_vector_dimension"] != 512
            or not isinstance(data["model_id"], str)
            or not isinstance(data["text_model_id"], str)
            or not isinstance(fields, list)
            or len(set(fields)) != len(fields)
            or any(not isinstance(field, str) for field in fields)
        ):
            raise ValueError("Invalid graph encoding metadata")
        exported = datetime.fromisoformat(data["exported_at"].replace("Z", "+00:00"))
        if exported.utcoffset() is None:
            raise ValueError("Export timestamp needs a timezone")
        self.metadata = {
            key: value for key, value in data.items() if key not in ("albums", "labels")
        }
        self.metadata["stale"] = (
            datetime.now(timezone.utc) - exported
        ).total_seconds() > 48 * 3600
        self.catalog = {}
        self.columns = {}
        for column in labels:
            identity = column["id"]
            if (
                not isinstance(identity, str)
                or identity in self.catalog
                or not isinstance(column["label"], str)
                or not isinstance(column["source"], str)
                or column["kind"]
                not in ("probability", "category", "relative", "zscore")
            ):
                raise ValueError("Invalid descriptor catalog entry")
            # Validate every column, but retain bytes rather than millions of floats.
            packed = unpack(column["scores"])
            low, high = column["min"], column["max"]
            if (
                len(packed) != len(rows)
                or not finite(low)
                or not finite(high)
                or low >= high
            ):
                raise ValueError("Invalid descriptor score column")
            self.catalog[identity] = column
            self.columns[identity] = packed
        self.albums = {}
        self.indices = {}
        for index, row in enumerate(rows):
            album = dict(row)
            identity = album["id"]
            if type(identity) is not int or identity <= 0 or identity in self.albums:
                raise ValueError("Invalid or duplicate album ID")
            count = album["track_count"]
            if type(count) is not int or count < 1:
                raise ValueError("Invalid track count")
            for key, dimension in (
                ("vector", data["vector_dimension"]),
                ("text_vector", 512),
            ):
                if album.get(key) is not None:
                    packed = unpack(album[key])
                    if len(packed) != dimension or not any(packed):
                        raise ValueError("Invalid album vector")
            essentia = album["essentia"]
            if not isinstance(essentia, list) or len(essentia) != len(fields):
                raise ValueError("Invalid Essentia field array")
            expanded = {}
            for name, entry in zip(fields, essentia):
                if entry is not None and (
                    not isinstance(entry, list)
                    or len(entry) not in (2, 3)
                    or type(entry[1]) is not int
                    or not 0 <= entry[1] <= count
                    or (
                        entry[0] is not None
                        and not isinstance(entry[0], str)
                        and not finite(entry[0])
                    )
                    or (len(entry) == 3 and not finite(entry[2]))
                ):
                    raise ValueError("Invalid Essentia value")
                expanded[name] = {
                    "value": entry[0] if entry else None,
                    "count": entry[1] if entry else 0,
                    "total": count,
                    "support": entry[2] if entry and len(entry) == 3 else None,
                }
            album["essentia"] = expanded
            sound = {}
            for source, group in album["sound"].items():
                decoded = []
                for pair in group["labels"]:
                    if (
                        not isinstance(pair, list)
                        or len(pair) != 2
                        or type(pair[0]) is not int
                        or not 0 <= pair[0] < len(labels)
                        or not finite(pair[1])
                    ):
                        raise ValueError("Invalid sound label reference")
                    column = labels[pair[0]]
                    decoded.append(
                        {
                            "id": column["id"],
                            "label": column["label"],
                            "score": pair[1],
                            "axis": column.get("axis"),
                        }
                    )
                sound[source] = {**group, "labels": decoded, "total": count}
            album["sound"] = sound
            self.albums[identity], self.indices[identity] = album, index

    @classmethod
    def read(cls, required=False):
        path = Path(
            os.environ.get(
                "LISTEN_ALBUM_GRAPH", "/var/lib/beets-album-graph/albums.json"
            )
        )
        try:
            data = json.loads(path.read_text())
        except OSError:
            if required:
                raise ListenError(
                    "graph_unavailable",
                    "Album graph export is missing or unreadable.",
                    72,
                ) from None
            return None
        except (ValueError, UnicodeError):
            if required:
                raise ListenError(
                    "graph_invalid", "Album graph export is invalid JSON.", 78
                ) from None
            return None
        try:
            return cls(data)
        except (ValueError, TypeError, KeyError, AttributeError, OverflowError):
            if required:
                raise ListenError(
                    "graph_invalid",
                    "Album graph export has invalid schema-v3 data or encodings.",
                    78,
                ) from None
            return None

    def descriptor(self, name):
        if name in self.catalog:
            return name
        matches = [
            identity
            for identity, column in self.catalog.items()
            if normalize(name) in (normalize(identity), normalize(column["label"]))
        ]
        if not matches:
            raise invalid(
                "Unknown descriptor; use listen descriptors to list available names."
            )
        if len(matches) > 1:
            raise ListenError(
                "ambiguous",
                "Descriptor name is ambiguous; use a catalog ID.",
                66,
                descriptor_candidates=[
                    self.catalog_info(identity) for identity in matches
                ],
            )
        return matches[0]

    def catalog_info(self, identity):
        return {
            key: value
            for key, value in self.catalog[identity].items()
            if key != "scores"
        }

    def score(self, identity, album_id):
        index = self.indices.get(album_id)
        if index is None:
            return None
        byte = self.columns[identity][index]
        column = self.catalog[identity]
        return (
            None
            if byte == 0
            else column["min"] + (byte - 1) * (column["max"] - column["min"]) / 254
        )

    def details(self, album_id):
        album = self.albums.get(album_id)
        if album is None:
            return None
        return {
            **album,
            "descriptors": {
                identity: value
                for identity in self.catalog
                if (value := self.score(identity, album_id)) is not None
            },
        }


class TextClient:
    def __init__(self, model_id):
        self.model_id = model_id
        self.endpoint = os.environ.get(
            "LISTEN_TEXT_ENDPOINT", "http://127.0.0.1:8765/api/embed-text"
        )
        self.timeout = number(
            os.environ.get("LISTEN_TEXT_TIMEOUT", "15"), positive=True
        )
        if self.timeout is None:
            raise ListenError(
                "configuration_invalid",
                "LISTEN_TEXT_TIMEOUT must be positive and finite.",
                78,
            )
        self.last_request = None

    def embed(self, phrase):
        phrase = phrase.strip()
        body = json.dumps({"q": phrase}, ensure_ascii=False).encode("utf-8")
        if not 1 <= len(phrase) <= 240 or len(body) > 4096:
            raise invalid(
                "Vibe phrases must be 1–240 characters and fit a 4 KiB request."
            )
        deadline = time.monotonic() + self.timeout
        for attempt in range(2):
            delay = (
                max(0, 0.55 - (time.monotonic() - self.last_request))
                if self.last_request is not None
                else 0
            )
            if delay >= deadline - time.monotonic():
                break
            time.sleep(delay)
            request = urllib.request.Request(
                self.endpoint,
                data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            self.last_request = time.monotonic()
            try:
                with urllib.request.urlopen(
                    request, timeout=max(0.001, deadline - time.monotonic())
                ) as response:
                    payload = response.read(65537)
                if len(payload) > 65536:
                    raise ValueError("Oversized text embedding response")
                data = json.loads(payload)
                vector = data["vector"]
                if (
                    not isinstance(vector, list)
                    or len(vector) != 512
                    or any(not finite(value) for value in vector)
                ):
                    raise ValueError("Invalid text embedding")
                norm = math.sqrt(sum(value * value for value in vector))
                if not math.isfinite(norm) or norm == 0:
                    raise ValueError("Invalid text embedding norm")
                if data.get("model_id") != self.model_id:
                    raise ListenError(
                        "text_model_mismatch",
                        "Text endpoint model_id does not match the album graph export.",
                        69,
                    )
                return [value / norm for value in vector]
            except urllib.error.HTTPError as exc:
                if exc.code == 429 and attempt == 0:
                    delay = number(exc.headers.get("Retry-After", 1))
                    delay = max(1, delay if delay is not None else 1)
                    if delay < deadline - time.monotonic():
                        time.sleep(delay)
                        continue
                raise ListenError(
                    "text_embedding_unavailable",
                    f"Text embedding endpoint returned HTTP {exc.code}.",
                    69,
                ) from None
            except (urllib.error.URLError, OSError, TimeoutError):
                raise ListenError(
                    "text_embedding_unavailable",
                    "Text embedding endpoint is unreachable or timed out.",
                    69,
                ) from None
            except (ValueError, TypeError, KeyError, UnicodeError, OverflowError):
                raise ListenError(
                    "text_embedding_invalid",
                    "Text embedding endpoint returned an invalid 512-dimensional vector.",
                    69,
                ) from None
        raise ListenError(
            "text_embedding_unavailable", "Text embedding endpoint timed out.", 69
        )

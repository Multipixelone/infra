"""Build original staff glyphs and substitute the digest of the served ZIP."""

import hashlib
import json
import pathlib
import struct
import sys
import zipfile
import zlib


def png(rows):
    assert len(rows) == 9 and all(len(row) == 9 for row in rows)
    palette = {
        ".": bytes((0, 0, 0, 0)),
        "#": bytes((128, 128, 128, 255)),
        "+": bytes((255, 255, 255, 255)),
    }
    raw = b"".join(b"\0" + b"".join(palette[pixel] for pixel in row) for row in rows)

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data))
        )

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 9, 9, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def build(client, ranks, output):
    with zipfile.ZipFile(client) as jar:
        version = json.loads(jar.read("version.json"))
    assert version["id"] == "26.3", "Review font compatibility when upgrading Minecraft"
    pack_version = [
        version["pack_version"]["resource_major"],
        version["pack_version"]["resource_minor"],
    ]
    assert pack_version == [97, 1]
    ranks = json.loads(pathlib.Path(ranks).read_text())
    glyphs = [style["glyph"] for style in ranks.values() if "glyph" in style]
    assert len(glyphs) == len(set(glyphs)) == 3
    assert all(len(glyph) == 1 and 0xE000 <= ord(glyph) <= 0xF8FF for glyph in glyphs)

    def encode(value):
        return (
            json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
            + "\n"
        ).encode()

    entries = {
        "pack.mcmeta": encode(
            {
                "pack": {
                    "pack_format": pack_version[0],
                    "min_format": pack_version,
                    "max_format": pack_version,
                    "description": "Original staff rank icons for Finn's Survival",
                }
            }
        ),
    }
    providers, translations = [], {}
    for rank, style in sorted(ranks.items()):
        if "glyph" not in style:
            continue
        entries[f"assets/infra/textures/font/{rank}.png"] = png(style["pixels"])
        providers.append(
            {
                "type": "bitmap",
                "file": f"infra:font/{rank}.png",
                "height": 9,
                "ascent": 8,
                "chars": [style["glyph"]],
            }
        )
        translations[f"infra.rank.{rank}"] = style["glyph"]
    entries["assets/infra/font/ranks.json"] = encode({"providers": providers})
    # Font provider lists from packs are combined; add only our private glyphs.
    entries["assets/minecraft/font/default.json"] = encode(
        {"providers": [{"type": "reference", "id": "infra:ranks"}]}
    )
    entries["assets/infra/lang/en_us.json"] = encode(translations)
    output = pathlib.Path(output)
    output.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(
        output / "rank-icons.zip", "w", compression=zipfile.ZIP_STORED
    ) as archive:
        for name, contents in sorted(entries.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, contents)
    (output / "sha1").write_text(
        hashlib.sha1((output / "rank-icons.zip").read_bytes()).hexdigest() + "\n"
    )


def properties(template, pack, output):
    digest = hashlib.sha1(
        (pathlib.Path(pack) / "rank-icons.zip").read_bytes()
    ).hexdigest()
    assert (pathlib.Path(pack) / "sha1").read_text().strip() == digest
    text = pathlib.Path(template).read_text()
    assert text.count("@RESOURCE_PACK_SHA1@") == 1
    pathlib.Path(output).write_text(text.replace("@RESOURCE_PACK_SHA1@", digest))


if __name__ == "__main__":
    {"build": build, "properties": properties}[sys.argv[1]](*sys.argv[2:])

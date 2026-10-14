"""Check the built ZIP, generated properties, and actual static download route."""

import hashlib
import json
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib

fixtures = json.loads(pathlib.Path(sys.argv[1]).read_text())
generator, client, discord_asset, nginx_template = sys.argv[2:]
fixture = fixtures["withLuckPerms"]
pack = pathlib.Path(fixture["rankPack"])
data = (pack / "rank-icons.zip").read_bytes()
digest = hashlib.sha1(data).hexdigest()
assert (pack / "sha1").read_text() == digest + "\n"
assert fixtures["noPaper"]["rankPack"] is None
with zipfile.ZipFile(client) as jar:
    version = json.loads(jar.read("version.json"))["pack_version"]
with zipfile.ZipFile(pack / "rank-icons.zip") as archive:
    ranks = {
        rank: style for rank, style in fixture["ranks"].items() if "glyph" in style
    }
    expected = {
        "pack.mcmeta",
        "assets/minecraft/font/default.json",
        "assets/infra/font/ranks.json",
        "assets/infra/font/chat.json",
        "assets/infra/textures/font/discord.png",
        "assets/infra/lang/en_us.json",
        *[f"assets/infra/textures/font/{rank}.png" for rank in ranks],
    }
    assert set(archive.namelist()) == expected
    assert archive.namelist() == sorted(expected)
    for entry in archive.infolist():
        assert entry.date_time == (1980, 1, 1, 0, 0, 0)
        assert entry.external_attr >> 16 == 0o100644
    metadata = json.loads(archive.read("pack.mcmeta"))["pack"]
    assert metadata["pack_format"] == version["resource_major"] == 97
    assert (
        metadata["min_format"]
        == metadata["max_format"]
        == [97, version["resource_minor"]]
        == [97, 1]
    )
    assert "supported_formats" not in metadata
    assert json.loads(archive.read("assets/minecraft/font/default.json")) == {
        "providers": [
            {"type": "reference", "id": "infra:ranks"},
            {"type": "reference", "id": "infra:chat"},
        ]
    }
    providers = json.loads(archive.read("assets/infra/font/ranks.json"))["providers"]
    translations = json.loads(archive.read("assets/infra/lang/en_us.json"))
    assert len(providers) == len(ranks) == 3
    assert len(translations) == 4
    assert {p["chars"][0] for p in providers} == {"\ue100", "\ue101", "\ue102"}
    chat_providers = json.loads(archive.read("assets/infra/font/chat.json"))[
        "providers"
    ]
    assert chat_providers == [
        {
            "type": "bitmap",
            "file": "infra:font/discord.png",
            "height": 9,
            "ascent": 8,
            "chars": ["\ue103"],
        }
    ]
    assert translations["infra.source.discord"] == "\ue103"
    glyphs = [provider["chars"][0] for provider in providers + chat_providers]
    assert len(glyphs) == len(set(glyphs)) == 4
    assert all(0xE000 <= ord(glyph) <= 0xF8FF for glyph in glyphs)
    discord = archive.read("assets/infra/textures/font/discord.png")
    assert discord == pathlib.Path(discord_asset).read_bytes()
    assert hashlib.sha256(discord).hexdigest() == (
        "faabe947d72a45358b27ee03ed87024b52be50da418b3033b0c5e78490103a89"
    )

    def pixels(image, width):
        assert image[:8] == b"\x89PNG\r\n\x1a\n"
        assert struct.unpack(">IIBBBBB", image[16:29]) == (width, 9, 8, 6, 0, 0, 0)
        offset, compressed = 8, b""
        while offset < len(image):
            length = struct.unpack(">I", image[offset : offset + 4])[0]
            kind, contents = (
                image[offset + 4 : offset + 8],
                image[offset + 8 : offset + 8 + length],
            )
            assert (
                zlib.crc32(kind + contents)
                == struct.unpack(
                    ">I", image[offset + 8 + length : offset + 12 + length]
                )[0]
            )
            assert kind in (b"IHDR", b"IDAT", b"IEND")
            if kind == b"IDAT":
                compressed += contents
            offset += length + 12
        raw = zlib.decompress(compressed)
        stride = 1 + width * 4
        assert len(raw) == 9 * stride
        assert all(raw[row * stride] == 0 for row in range(9))
        return [
            raw[row * stride + 1 + col * 4 : row * stride + 5 + col * 4]
            for row in range(9)
            for col in range(width)
        ]

    logo_pixels = pixels(discord, 12)
    assert all(pixel[:3] == b"\xff\xff\xff" for pixel in logo_pixels if pixel[3])
    assert 0 in {pixel[3] for pixel in logo_pixels}
    assert any(pixel[3] > 0 for pixel in logo_pixels)
    for rank, style in ranks.items():
        assert translations[f"infra.rank.{rank}"] == style["glyph"]
        assert f"<lang_or:infra.rank.{rank}:'[{style['label']}]'>" in style["prefix"]
        assert f"<hover:show_text:'{style['label']}'>" in style["prefix"]
        provider = next(p for p in providers if p["chars"] == [style["glyph"]])
        assert provider == {
            "type": "bitmap",
            "file": f"infra:font/{rank}.png",
            "height": 9,
            "ascent": 8,
            "chars": [style["glyph"]],
        }
        image = archive.read(f"assets/infra/textures/font/{rank}.png")
        alphas = [pixel[3] for pixel in pixels(image, 9)]
        assert set(alphas) == {0, 255}
    assert "prefix" not in fixture["ranks"]["default"]

for name, case in fixtures.items():
    if name == "noPaper":
        assert not case["servers"]
        continue
    assert case["rankPack"] == str(pack)
    assert not any("Geyser-Velocity/packs/" in path for path in case["proxySymlinks"])
    for server_id, server in case["servers"].items():
        source = server["configTemplates"][
            f"/srv/games/minecraft/{server_id}/server.properties"
        ]["source"]
        properties = dict(
            line.split("=", 1)
            for line in pathlib.Path(source).read_text().splitlines()
            if line
        )
        assert (
            properties["resource-pack"] == case["rankPackUrl"] == fixture["rankPackUrl"]
        )
        assert properties["resource-pack-sha1"] == digest
        assert properties["require-resource-pack"] == "true"
        prompt = json.loads(properties["resource-pack-prompt"])["text"]
        assert "staff rank and Discord chat icons" in prompt
        assert "must accept it to join" in prompt
        assert properties["rcon.password"] == "@RCON@"

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    # Rebuilding from differently ordered input must produce identical bytes.
    for index, styles in enumerate(
        (fixture["ranks"], dict(reversed(list(fixture["ranks"].items()))))
    ):
        source = root / f"ranks-{index}.json"
        source.write_text(json.dumps(styles))
        output = root / f"pack-{index}"
        subprocess.run(
            [
                sys.executable,
                generator,
                "build",
                client,
                str(source),
                discord_asset,
                str(output),
            ],
            check=True,
        )
        assert (output / "rank-icons.zip").read_bytes() == data
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    configuration = root / "nginx.conf"
    configuration.write_text(
        pathlib.Path(nginx_template)
        .read_text()
        .replace("@ROOT@", directory)
        .replace("@PORT@", str(port))
    )
    process = subprocess.Popen(
        ["nginx", "-c", str(configuration), "-p", directory, "-g", "daemon off;"]
    )
    url = (
        f"http://127.0.0.1:{port}" + urllib.parse.urlsplit(fixture["rankPackUrl"]).path
    )
    try:
        for attempt in range(100):
            try:
                with urllib.request.urlopen(url, timeout=2) as response:
                    assert response.status == 200 and response.read() == data
                    assert response.headers["Content-Type"] == "application/zip"
                    assert int(response.headers["Content-Length"]) == len(data)
                    assert "immutable" in response.headers["Cache-Control"]
                    break
            except urllib.error.URLError:
                if attempt == 99:
                    raise
                time.sleep(0.02)
        with urllib.request.urlopen(
            urllib.request.Request(url, method="HEAD"), timeout=2
        ) as response:
            assert response.status == 200 and response.read() == b""
        try:
            urllib.request.urlopen(
                urllib.request.Request(url, method="POST"), timeout=2
            )
            raise AssertionError("pack route accepted a write request")
        except urllib.error.HTTPError as error:
            assert error.code == 405
    finally:
        process.terminate()
        process.wait(timeout=5)

print(
    "PASS: reproducible rank/Discord glyph pack, format 97.1, properties SHA-1, static download without Paper"
)

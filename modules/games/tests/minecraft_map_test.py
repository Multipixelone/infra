"""Check BlueMap's compiled static player writer, privacy and nginx delivery."""

import io
import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

(
    fixtures_file, plugin, java_source, tokens_file, nginx_template, paper, gson,
    players_source, helper_source,
) = sys.argv[1:]
data = json.loads(pathlib.Path(fixtures_file).read_text())
tokens = pathlib.Path(tokens_file).read_text()
assert data["without"] == {}
assert data["root"] == "/srv/games/minecraft/survival/plugins/BlueMap/web"
assert data["homepageCSS"].startswith(tokens + "\n")
assert "#services" in data["homepageCSS"]

with (
    zipfile.ZipFile(plugin) as jar,
    zipfile.ZipFile(io.BytesIO(jar.read("de/bluecolored/bluemap/webapp.zip"))) as web,
):
    css = "\n".join(web.read(n).decode() for n in web.namelist() if n.endswith(".css"))
    scripts = "\n".join(
        web.read(n).decode() for n in web.namelist() if n.endswith(".js")
    )
    for selector in (
        ".theme-light",
        ".theme-dark",
        ".theme-contrast",
        ".side-menu",
        ".svg-button",
        ".text-input",
        ".compass",
        "#zoom-buttons",
        ".map-state-message",
        ".bm-marker-poi-label",
        ".bm-marker-popup",
        ".bm-marker-labelpopup",
    ):
        assert selector in css, f"BlueMap selector changed: {selector}"
    for variable in (
        "--theme-bg",
        "--theme-bg-hover",
        "--theme-bg-light",
        "--theme-fg",
        "--theme-fg-light",
    ):
        assert variable in css, f"BlueMap variable changed: {variable}"
    assert 'createElement("link")' in scripts and 'rel="stylesheet"' in scripts
    assert 'liveDataRoot:"maps"' in scripts
    assert 'e.data.liveDataRoot+"/live/players.json"' in scripts
    assert "SSE event source error - enabling polling" in scripts
    assert "this.playerMarkerManager.setAutoUpdateInterval(1e3)" in scripts

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    # Paper provides Configurate's option library; vanilla provides Gson.
    # Supply the same pinned runtime libraries without starting a server.
    embedded = root / "paperlibs"
    embedded.mkdir()
    with zipfile.ZipFile(paper) as jar:
        for name in jar.namelist():
            if name.startswith("META-INF/libraries/") and name.endswith(".jar"):
                (embedded / pathlib.Path(name).name).write_bytes(jar.read(name))
    classes = root / "classes"
    classes.mkdir()
    classpath = f"{classes}:{plugin}:{gson}:{embedded}/*"
    sources = []
    for name, source in (
        ("ReadBlueMapWebSettings.java", java_source),
        ("CheckBlueMapPlayers.java", players_source),
        ("BlueMapFixture.java", helper_source),
    ):
        target = root / name
        target.write_text(pathlib.Path(source).read_text())
        sources.append(str(target))
    subprocess.run(
        ["javac", "-cp", classpath, "-d", str(classes), *sources],
        check=True,
    )
    style_content = None
    for scenario in ("production", "additional"):
        assert set(data[scenario]) == (
            {"survival", "testing"} if scenario == "additional" else {"survival"}
        )
        for identifier, server in data[scenario].items():
            destination = f"/srv/games/minecraft/{identifier}/plugins/BlueMap"
            template = server["templates"][destination + "/web/css/homepage-theme.css"]
            assert template["mode"] == "0644"
            assert (
                template
                == server["runtimeTemplates"][
                    destination + "/web/css/homepage-theme.css"
                ]
            )
            content = pathlib.Path(template["source"]).read_text()
            assert content.startswith(tokens + "\n")
            assert "#services" not in content and "#background" not in content
            assert "@font-face" not in content and "@import" not in content
            if style_content is not None:
                assert content == style_content
            style_content = content
            webroot = root / "web"
            (webroot / "css").mkdir(parents=True, exist_ok=True)
            (webroot / "css/homepage-theme.css").write_text(content)
            subprocess.run(
                [
                    "java",
                    "-cp",
                    classpath,
                    "ReadBlueMapWebSettings",
                    server["templates"][destination + "/webapp.conf"]["source"],
                    str(webroot),
                    destination + "/web",
                ],
                check=True,
            )
            settings = json.loads((webroot / "settings.json").read_text())
            assert settings["styles"] == ["css/homepage-theme.css"]
            assert settings["scripts"] == []
            assert settings["clientDecompression"]
            assert (
                '<meta name="version" content="5.28">'
                in (webroot / "index.html").read_text()
            )
            player_fixture = root / f"{scenario}-{identifier}"
            for name in ("plugin.conf", "webserver.conf"):
                assert server["templates"][destination + "/" + name] == server["runtimeTemplates"][destination + "/" + name]
            subprocess.run(
                [
                    "java", "-cp", classpath, "CheckBlueMapPlayers",
                    server["templates"][destination + "/plugin.conf"]["source"],
                    server["templates"][destination + "/webserver.conf"]["source"],
                    str(player_fixture),
                ],
                check=True,
            )

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

    def request(path, method="GET"):
        try:
            with urllib.request.urlopen(
                urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method),
                timeout=2,
            ) as response:
                return response.status, response.headers, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.headers, error.read()

    try:
        for _ in range(100):
            try:
                if request("/settings.json")[0] == 200:
                    break
            except urllib.error.URLError:
                time.sleep(0.02)
        status, _, settings = request("/settings.json")
        assert status == 200
        url = json.loads(settings)["styles"][0]
        status, headers, content = request("/" + url)
        assert status == 200 and content.decode() == style_content
        assert headers["X-Content-Type-Options"] == "nosniff"
        assert headers.get_content_type() == "text/css"
        assert request("/" + url, "HEAD")[0] == 200
        assert request("/" + url, "POST")[0] == 405
        feed = webroot / "maps/world/live/players.json"
        feed.parent.mkdir(parents=True, exist_ok=True)
        for scenario in ("online", "moved", "foreign", "empty", "stopped"):
            expected = (player_fixture / f"snapshots/{scenario}.json").read_bytes()
            feed.write_bytes(expected)
            status, headers, actual = request("/maps/world/live/players.json")
            assert status == 200 and actual == expected
            assert headers.get_content_type() == "application/json"
            assert headers["Cache-Control"] == "no-store"
            assert headers["X-Content-Type-Options"] == "nosniff"
            assert headers["Referrer-Policy"] == "no-referrer"
            assert request("/maps/world/live/players.json", "HEAD")[0] == 200
            assert request("/maps/world/live/players.json", "POST")[0] == 405
        markers = webroot / "maps/world/live/markers.json"
        expected = (player_fixture / "web/maps/world/live/markers.json").read_bytes()
        markers.write_bytes(expected)
        assert request("/maps/world/live/markers.json")[2] == expected
        assert request("/maps/world/live/sse")[0] == 404
        assert request("/maps/missing/live/players.json")[0] == 404
        private = webroot / "maps/.private/live/players.json"
        private.parent.mkdir(parents=True)
        private.write_text("private")
        assert request("/maps/.private/live/players.json")[0] == 403
        assert request("/maps/world/live/")[0] == 403
    finally:
        process.terminate()
        process.wait(timeout=5)

print(
    "PASS: every backend, pinned BlueMap writer/privacy, static player polling and protected nginx serving"
)

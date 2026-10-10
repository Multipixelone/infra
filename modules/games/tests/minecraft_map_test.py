"""Check actual BlueMap registration, webroot updates and sleeping-map CSS serving."""

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

fixtures_file, plugin, java_source, tokens_file, nginx_template, paper, gson = sys.argv[
    1:
]
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
    source = root / "ReadBlueMapWebSettings.java"
    source.write_text(pathlib.Path(java_source).read_text())
    subprocess.run(
        ["javac", "-cp", classpath, "-d", str(classes), str(source)], check=True
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
    finally:
        process.terminate()
        process.wait(timeout=5)

print(
    "PASS: shared Homepage tokens, every backend, pinned BlueMap loader/updater and static CSS serving"
)

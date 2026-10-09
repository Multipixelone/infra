"""Optional credentials must not disable Minecraft; static maps survive sleep."""
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

cases = json.loads(pathlib.Path(sys.argv[1]).read_text())
for case in cases:
    assert case["installed"] == case["expected"]
    assert not case["baseAvailable"]  # No mandatory Minecraft credentials in these fixtures.
    if case["expected"]:
        assert case["tokenCopy"] == {"secret": "/run/agenix/games/minecraft/discordsrv-token"}
        assert case["declaredSecret"] == "0400"
        assert any(path.endswith("plugins/DiscordSRV") for path in case["statePaths"])
    else:
        assert case["tokenCopy"] is None
        assert not any(path.endswith("plugins/DiscordSRV") for path in case["statePaths"])
    assert any(path.endswith("plugins/BlueMap") for path in case["statePaths"])
    assert any(path.endswith("plugins/SkinsRestorer") for path in case["statePaths"])

with zipfile.ZipFile(sys.argv[3]) as jar:
    assert "libraries:" not in jar.read("plugin.yml").decode()
    assert "com/flowpowered/math/vector/Vector3d.class" in jar.namelist()
cache = pathlib.Path(sys.argv[4])
assert (cache / "postgresql-driver-42.7.6.jar").exists()
with zipfile.ZipFile(cache / "postgresql-driver-42.7.6-remapped.jar") as jar:
    assert "me/lucko/luckperms/lib/postgresql/Driver.class" in jar.namelist()

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    (root / "web").mkdir()
    (root / "web/index.html").write_text("persisted map")
    (root / "web/.token").write_text("private fixture")
    (root / "secret.txt").write_text("outside webroot")
    (root / "web/tiles").mkdir()
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    configuration = root / "nginx.conf"
    configuration.write_text(pathlib.Path(sys.argv[2]).read_text().replace("@ROOT@", directory).replace("@PORT@", str(port)))
    process = subprocess.Popen(["nginx", "-c", str(configuration), "-p", directory, "-g", "daemon off;"])
    def request(path, method="GET"):
        try:
            with urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method), timeout=2) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            return error.code, error.read()
    try:
        for _ in range(100):
            try:
                if request("/index.html")[0] == 200:
                    break
            except urllib.error.URLError:
                time.sleep(0.02)
        # No game/proxy process is running in this test.
        assert request("/index.html") == (200, b"persisted map")
        assert request("/index.html", "HEAD")[0] == 200
        assert request("/index.html", "POST")[0] == 405
        assert request("/.token")[0] == 403
        assert request("/tiles/")[0] == 403
        status, content = request("/../secret.txt")
        assert 400 <= status < 500 and b"outside webroot" not in content
    finally:
        process.terminate()
        process.wait(timeout=5)

"""Regression: a live SSE connection must not block the supervised dev reload."""

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


def test_reload_with_live_sse_and_ctrl_c_cleanup(tmp_path):
    backend_source = Path(__file__).resolve().parents[1]
    backend = tmp_path / "pkgs/games-dashboard/backend"
    backend.mkdir(parents=True)
    shutil.copytree(
        backend_source / "games_dashboard",
        backend / "games_dashboard",
        ignore=shutil.ignore_patterns("__pycache__"),
    )
    shutil.copyfile(backend_source / "dev.py", backend / "dev.py")
    vite = tmp_path / "pkgs/games-dashboard/frontend/node_modules/vite/bin/vite.js"
    vite.parent.mkdir(parents=True)
    vite.touch()
    # The backend regression needs only a long-lived frontend process/listener.
    # The separate smoke exercises the real Vite proxy and npm recipe.
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    npm = bin_dir / "npm"
    npm.write_text(
        f"#!{sys.executable}\n"
        "import os\nfrom http.server import HTTPServer, BaseHTTPRequestHandler\n"
        "HTTPServer(('127.0.0.1', int(os.environ['PORT'])), BaseHTTPRequestHandler).serve_forever()\n"
    )
    npm.chmod(0o755)
    while True:
        with socket.socket() as first, socket.socket() as second:
            first.bind(("127.0.0.1", 0))
            port = first.getsockname()[1]
            if port == 65535:
                continue
            try:
                second.bind(("127.0.0.1", port + 1))
            except OSError:
                continue
            break
    env = os.environ | {
        "PORT": str(port),
        "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
        "GAMES_DASHBOARD_MOCK": "1",
    }
    url = f"http://127.0.0.1:{port + 1}/api/servers"

    def state():
        try:
            with urllib.request.urlopen(url, timeout=0.3) as response:
                data = json.load(response)
                return next(
                    server["status"]["state"]
                    for server in data["servers"]
                    if server["id"] == "survival"
                )
        except OSError:
            return None

    def await_running():
        deadline = time.monotonic() + 8
        while state() != "running":
            assert time.monotonic() < deadline, "dev startup/reload stalled"
            assert process.poll() is None, "dev supervisor exited"
            time.sleep(0.05)

    with (tmp_path / "dev.log").open("w") as log:
        process = subprocess.Popen(
            [sys.executable, str(backend / "dev.py")],
            cwd=tmp_path,
            env=env,
            stdout=log,
            stderr=log,
            start_new_session=True,
        )
        stream = None
        try:
            await_running()
            request = urllib.request.Request(url + "/survival/stop", method="POST")
            with urllib.request.urlopen(request, timeout=1) as response:
                assert json.load(response)["status"]["state"] == "stopped"
            stream = urllib.request.urlopen(url + "/survival/events", timeout=1)
            assert stream.readline() == b"event: log\n"
            # Watchfiles needs a moment to finish installing its initial watches.
            time.sleep(0.3)
            reload_source = backend / "games_dashboard/app.py"
            # copytree retains the read-only mode of sources from the Nix store.
            reload_source.chmod(0o644)
            with reload_source.open("a") as source:
                source.write("\n# temporary reload fixture\n")
            # Keep the original SSE response open until after reload completes.
            await_running()
        finally:
            if stream is not None:
                stream.close()
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGINT)
            try:
                process.wait(timeout=7)
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
        assert process.returncode == 0
        for listener in (port, port + 1):
            with socket.socket() as connection:
                assert connection.connect_ex(("127.0.0.1", listener)) != 0

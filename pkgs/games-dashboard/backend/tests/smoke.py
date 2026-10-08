"""Bounded integration smoke: actual just recipe, Vite proxy, SSE, and cleanup."""

import json
import os
import signal
import socket
import subprocess
import time
import urllib.error
import urllib.request


def listening(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            return True
    except OSError:
        return False


def main():
    port = int(os.environ.get("PORT", "5173"))
    if listening(port) or listening(port + 1):
        raise RuntimeError("smoke ports already in use; choose another PORT")
    process = subprocess.Popen(
        ["just", "games-dashboard-dev"],
        env=os.environ | {"PORT": str(port), "GAMES_DASHBOARD_MOCK": "1"},
        start_new_session=True,
    )
    deadline = time.monotonic() + 50
    try:
        url = f"http://127.0.0.1:{port}/api/servers"
        while True:
            if process.poll() is not None:
                raise RuntimeError("dev recipe exited before readiness")
            try:
                with urllib.request.urlopen(url, timeout=2) as response:
                    data = json.load(response)
                break
            except (OSError, urllib.error.HTTPError):
                if time.monotonic() >= deadline:
                    raise RuntimeError("dev recipe did not become ready") from None
                time.sleep(0.2)
        assert data["schemaVersion"] == 1 and data["servers"]
        identifier = data["servers"][0]["id"]
        print(
            f"PASS /api/servers through Vite: {len(data['servers'])} servers",
            flush=True,
        )
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/api/servers/{identifier}/events", timeout=5
        ) as response:
            assert response.headers.get_content_type() == "text/event-stream"
            events = 0
            while events < 2 and time.monotonic() < deadline:
                line = response.readline().decode()
                if line.startswith("data: "):
                    entry = json.loads(line[6:])
                    assert entry["id"] == identifier and entry["line"]
                    events += 1
            assert events == 2
        print("PASS multiple SSE events through Vite", flush=True)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGINT)
        try:
            process.wait(timeout=7)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=3)
        cleanup_deadline = time.monotonic() + 2
        while (
            listening(port) or listening(port + 1)
        ) and time.monotonic() < cleanup_deadline:
            time.sleep(0.1)
        assert not listening(port) and not listening(port + 1), (
            "dev listeners survived Ctrl-C"
        )
        print("PASS Ctrl-C stopped both listeners", flush=True)


if __name__ == "__main__":
    main()

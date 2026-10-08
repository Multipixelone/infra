"""Bounded packaged-app smoke, optionally through the evaluated nginx config."""

import argparse
import base64
import http.client
import json
import os
import re
import signal
import socket
import subprocess
import tempfile
import time
from pathlib import Path


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=2)


def request(port, path, headers=None, method="GET"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request(method, path, headers=headers or {})
        response = connection.getresponse()
        return response.status, response.read(), response.getheader("Content-Type", "")
    finally:
        connection.close()


def events(port, identifier, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request(
            "GET", f"/api/servers/{identifier}/events", headers=headers or {}
        )
        response = connection.getresponse()
        assert response.status == 200
        assert response.getheader("Content-Type").startswith("text/event-stream")
        started = time.monotonic()
        entries = []
        while len(entries) < 2 and time.monotonic() - started < 5:
            line = response.readline().decode()
            if line.startswith("data: "):
                entries.append(json.loads(line[6:]))
        assert len(entries) == 2 and all(entry["id"] == identifier for entry in entries)
        assert time.monotonic() - started < 5, "nginx buffered the event stream"
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", required=True)
    parser.add_argument("--nginx")
    parser.add_argument("--proxy-config")
    parser.add_argument("--htpasswd")
    args = parser.parse_args()
    # All fixtures and child output stay in the tool's permitted temp area.
    os.makedirs("/tmp/opencode", exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="games-dashboard-smoke-", dir="/tmp/opencode"
    ) as temporary:
        root = Path(temporary)
        backend_port = free_port()
        with (root / "app.log").open("w+") as output:
            process = subprocess.Popen(
                [args.executable, "--port", str(backend_port)],
                env=os.environ
                | {
                    "GAMES_DASHBOARD_MOCK": "1",
                    "GAMES_DASHBOARD_ORIGIN": "https://games.nyc.finnrut.is",
                },
                stdout=output,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            proxy = None
            try:
                deadline = time.monotonic() + 35
                while True:
                    assert process.poll() is None, (
                        "packaged app exited before readiness"
                    )
                    try:
                        if request(backend_port, "/healthz")[0] == 200:
                            break
                    except OSError:
                        pass
                    assert time.monotonic() < deadline, (
                        "packaged app did not become ready"
                    )
                    time.sleep(0.1)
                status, body, _ = request(backend_port, "/healthz")
                assert status == 200 and json.loads(body) == {"status": "ok"}
                status, body, _ = request(backend_port, "/")
                assert status == 200
                assets = re.findall(r'(?:src|href)="(/assets/[^"]+)"', body.decode())
                assert assets and all(
                    request(backend_port, asset)[0] == 200 for asset in assets
                )
                assert request(backend_port, "/api/unknown")[0] == 404
                status, body, _ = request(backend_port, "/api/servers")
                inventory = json.loads(body)
                assert (
                    status == 200
                    and inventory["schemaVersion"] == 1
                    and inventory["servers"]
                )
                identifier = inventory["servers"][0]["id"]
                events(backend_port, identifier)
                print(
                    "PASS packaged healthz, UI/assets, inventory and multiple SSE events",
                    flush=True,
                )

                if args.proxy_config:
                    proxy_port = free_port()
                    subprocess.run(
                        [
                            args.htpasswd,
                            "-cBb",
                            str(root / "htpasswd"),
                            "finn",
                            "fixture-password",
                        ],
                        check=True,
                        capture_output=True,
                    )
                    text = Path(args.proxy_config).read_text()
                    for key, value in {
                        "ROOT": str(root),
                        "BACKEND_PORT": str(backend_port),
                        "PROXY_PORT": str(proxy_port),
                    }.items():
                        text = text.replace(f"@{key}@", value)
                    config = root / "nginx.conf"
                    config.write_text(text)
                    proxy = subprocess.Popen(
                        [
                            args.nginx,
                            "-c",
                            str(config),
                            "-p",
                            str(root),
                            "-g",
                            "daemon off;",
                        ],
                        stdout=output,
                        stderr=subprocess.STDOUT,
                        start_new_session=True,
                    )
                    lan = {"X-Test-Client-IP": "192.168.6.42"}
                    auth = {
                        "Authorization": "Basic "
                        + base64.b64encode(b"finn:fixture-password").decode()
                    }
                    while True:
                        assert proxy.poll() is None, "nginx fixture exited"
                        try:
                            if request(proxy_port, "/healthz", lan)[0] == 200:
                                break
                        except OSError:
                            pass
                        assert time.monotonic() < deadline, "nginx did not become ready"
                        time.sleep(0.1)
                    for address in (
                        "192.168.3.42",
                        "192.168.5.42",
                        "192.168.6.42",
                        "10.100.0.42",
                    ):
                        client = {"X-Test-Client-IP": address}
                        assert request(proxy_port, "/healthz", client)[0] == 200
                        for path in (
                            "/",
                            "/api/servers",
                            f"/api/servers/{identifier}/events",
                            "/healthz/",
                            "/docs",
                        ):
                            assert request(proxy_port, path, client)[0] == 401
                        assert (
                            request(proxy_port, "/api/servers", client | auth)[0] == 200
                        )
                        assert (
                            request(
                                proxy_port,
                                f"/api/servers/{identifier}/stop",
                                client,
                                "POST",
                            )[0]
                            == 401
                        )
                    for address in (
                        "203.0.113.42",
                        "198.51.100.42",
                        "192.168.7.42",
                        "192.168.8.42",
                    ):
                        client = {"X-Test-Client-IP": address} | auth
                        for path in ("/", "/healthz", "/api/servers"):
                            assert request(proxy_port, path, client)[0] == 403
                    assert (
                        request(
                            proxy_port,
                            "/",
                            lan | {"Authorization": "Basic ZmlubjpiYWQ="},
                        )[0]
                        == 401
                    )
                    assert (
                        request(
                            proxy_port,
                            f"/api/servers/{identifier}/stop",
                            lan | auth,
                            "POST",
                        )[0]
                        == 403
                    )
                    assert (
                        request(
                            proxy_port,
                            f"/api/servers/{identifier}/stop",
                            lan | auth | {"Origin": "https://evil.example"},
                            "POST",
                        )[0]
                        == 403
                    )
                    assert (
                        request(
                            proxy_port,
                            f"/api/servers/{identifier}/stop",
                            lan | auth | {"Origin": "https://games.nyc.finnrut.is"},
                            "POST",
                        )[0]
                        == 200
                    )
                    events(proxy_port, identifier, lan | auth)
                    print(
                        "PASS generated nginx: LAN/VPN auth, public denial, exact health exception, origins and unbuffered SSE",
                        flush=True,
                    )
            except BaseException:
                output.flush()
                print((root / "app.log").read_text(), flush=True)
                raise
            finally:
                if proxy is not None:
                    stop(proxy)
                stop(process)
                with socket.socket() as listener:
                    listener.bind(("127.0.0.1", backend_port))
                print("PASS packaged listener cleanup", flush=True)


if __name__ == "__main__":
    main()

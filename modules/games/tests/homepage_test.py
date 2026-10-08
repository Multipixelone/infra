"""Check generated Homepage contracts and actual loopback status responses."""

import importlib.util
import json
import socket
import sys
import threading
import urllib.error
import urllib.request
from unittest.mock import patch


def games(groups):
    matching = [group["Games"] for group in groups if "Games" in group]
    assert len(matching) == 1
    return {name: tile for entry in matching[0] for name, tile in entry.items()}


def contract(data):
    services = data["services"]
    ready = games(services["enabled"])
    assert list(ready) == ["Survival", "Terraria", "Games dashboard"]
    assert ready["Survival"]["widget"] == {
        "type": "minecraft",
        "url": "udp://127.0.0.1:25566",
        "fields": ["players", "version", "status"],
    }
    assert "mc.finnrut.is" in ready["Survival"]["description"]
    assert "Up includes sleeping" in ready["Survival"]["description"]
    assert "terraria.finnrut.is:7777" in ready["Terraria"]["description"]
    assert ready["Terraria"]["widget"]["type"] == "customapi"
    assert ready["Terraria"]["widget"]["url"].endswith("/servers/terraria")
    assert ready["Games dashboard"]["href"] == "https://games.nyc.finnrut.is"
    for scenario in ("missing", "empty"):
        assert list(games(services[scenario])) == ["Games dashboard"]
    for scenario in ("disabled", "stopped"):
        assert list(games(services[scenario])) == ["Terraria", "Games dashboard"]
    discovered = games(services["discovered"])
    assert list(discovered) == ["Creative", "Survival", "Terraria", "Games dashboard"]
    assert discovered["Creative"]["widget"]["url"] == "udp://127.0.0.1:25576"
    original = [group for group in services["empty"] if "Games" not in group]
    assert original and original == [
        group for group in services["enabled"] if "Games" not in group
    ]
    assert data["adapter"]["DynamicUser"]
    assert data["adapter"]["IPAddressAllow"] == "localhost"
    assert not data["adapterMissing"]
    assert 18777 not in data["tcp"] + data["udp"]
    assert data["deduplicated"] == [
        {"Media": [{"Plex": {"href": "https://plex.example.test"}}]},
        {
            "Games": [
                {"Other": {"description": "keep me"}},
                {"Games dashboard": ready["Games dashboard"]},
            ]
        },
    ]
    assert (
        games([{"Games": data["alternate"]}])["Games dashboard"]["href"]
        == "https://games.example.test"
    )


def adapter(path):
    spec = importlib.util.spec_from_file_location("homepage_status", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    with socket.socket() as listener, socket.socket() as closed:
        listener.bind(("127.0.0.1", 0))
        listener.listen()
        closed.bind(("127.0.0.1", 0))
        closed_port = closed.getsockname()[1]
        with module.make_server(
            {"open": listener.getsockname()[1], "closed": closed_port}, port=0
        ) as server:
            assert server.server_address[0] == "127.0.0.1"
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            url = f"http://127.0.0.1:{server.server_port}"
            try:
                for name, expected in (("open", "Up"), ("closed", "Down")):
                    with urllib.request.urlopen(f"{url}/servers/{name}") as response:
                        assert response.headers["Cache-Control"] == "no-store"
                        assert json.load(response) == {"status": expected}
                with listener.accept()[0] as connection:
                    assert connection.recv(1) == b"", "probe sent game payload"
                with patch.object(
                    module.socket, "create_connection", side_effect=TimeoutError
                ):
                    assert module.tcp_status(listener.getsockname()[1]) == "Down"
                for request_path in (
                    "/servers/unknown",
                    "/servers/open?port=22",
                    "/other",
                    "/servers/open/../closed",
                ):
                    try:
                        urllib.request.urlopen(url + request_path)
                    except urllib.error.HTTPError as error:
                        assert error.code == 404
                    else:
                        raise AssertionError(f"accepted unknown path {request_path}")
            finally:
                server.shutdown()
                thread.join(timeout=2)
    print(
        "Homepage discovery, prerequisites, grouping, and loopback TCP adapter passed"
    )


if __name__ == "__main__":
    with open(sys.argv[1]) as fixture:
        contract(json.load(fixture))
    adapter(sys.argv[2])

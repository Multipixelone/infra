import asyncio
import json
from urllib.parse import quote

import pytest
from fastapi.testclient import TestClient
from games_dashboard.adapters import HelperFailure, MockAdapter, RealAdapter, Runner
from games_dashboard.app import configured_adapter, create_app, sse_events
from games_dashboard.models import Manifest
from pydantic import ValidationError


def test_manifest_schema_parity(manifest_data, manifest):
    # The fixture is the actual games-contract enabled NixOS manifest output.
    # Strict nested models and exact round-trip make schema drift fail here.
    assert manifest.model_dump(mode="json") == manifest_data
    assert manifest.schemaVersion == 1
    assert {server.console.method for server in manifest.servers} == {
        "rcon",
        "container-inject",
    }


@pytest.mark.parametrize("mutation", ["version", "extra", "missing", "argv", "unit"])
def test_manifest_rejects_drift(manifest_data, mutation):
    server = manifest_data["servers"][0]
    if mutation == "version":
        manifest_data["schemaVersion"] = 2
    elif mutation == "extra":
        server["console"]["newField"] = True
    elif mutation == "missing":
        del server["backup"]["enabled"]
    elif mutation == "argv":
        server["statusCommand"] = ["sh", "-c", "games-status"]
    elif mutation == "unit":
        server["unit"] = "--user"
    with pytest.raises(ValidationError):
        Manifest.model_validate(manifest_data)


def test_mock_list_and_state_transitions(manifest):
    adapter = MockAdapter(manifest)
    with TestClient(create_app(adapter)) as client:
        data = client.get("/api/servers").json()
        assert data["schemaVersion"] == 1
        assert data["sharedServices"] == manifest.model_dump()["sharedServices"]
        servers = {item["id"]: item for item in data["servers"]}
        assert servers["survival"]["status"]["playersOnline"] == 2
        assert servers["terraria"]["status"]["playersOnline"] is None
        for identifier, started in (("survival", "sleeping"), ("terraria", "running")):
            for action, state in (
                ("stop", "stopped"),
                ("start", started),
                ("restart", started),
            ):
                response = client.post(f"/api/servers/{identifier}/{action}")
                assert response.status_code == 200
                assert response.json()["status"]["state"] == state
            before = client.get("/api/servers").json()
            backup = client.post(f"/api/servers/{identifier}/backup")
            assert backup.status_code == 200
            assert backup.json()["status"]["state"] == started
            assert adapter.backups[identifier] == 1
            assert client.get("/api/servers").json() == before


def test_mock_backup_preserves_stopped_state(manifest):
    with TestClient(create_app(MockAdapter(manifest))) as client:
        response = client.post("/api/servers/terraria/backup")
        assert response.json()["status"]["state"] == "stopped"


def test_discovery_is_not_hardcoded(manifest_data):
    server = json.loads(json.dumps(manifest_data["servers"][0]))
    server["id"] = "creative"
    for field in ("statusCommand", "logsCommand"):
        server[field][1] = "creative"
    for field in ("console", "backup"):
        server[field]["command"][1] = "creative"
    server["unit"] = "minecraft-server-creative.service"
    manifest_data["servers"].append(server)
    with TestClient(
        create_app(MockAdapter(Manifest.model_validate(manifest_data)))
    ) as client:
        assert "creative" in {
            item["id"] for item in client.get("/api/servers").json()["servers"]
        }
        assert client.post("/api/servers/creative/stop").status_code == 200


class RecordingRunner:
    def __init__(self, manifest):
        self.calls = []
        self.status = [
            item.model_dump() for item in MockAdapter(manifest).state.values()
        ]
        self.closed = False

    async def run(self, argv, timeout):
        self.calls.append((argv, timeout))
        return json.dumps(self.status).encode() if argv == ["games-status"] else b""

    async def lines(self, argv):
        self.calls.append((argv, None))
        try:
            yield "journal line"
            await asyncio.sleep(3600)
        finally:
            self.closed = True


@pytest.mark.parametrize("mode", ["mock", "real"])
@pytest.mark.parametrize(
    "identifier", ["sshd.service", "velocity", "--help", "x;touch pwned", "$(id)"]
)
def test_unknown_ids_never_execute(manifest, mode, identifier):
    runner = RecordingRunner(manifest)
    adapter = RealAdapter(manifest, runner) if mode == "real" else MockAdapter(manifest)
    with TestClient(create_app(adapter)) as client:
        for action in ("start", "stop", "restart", "backup", "events"):
            url = f"/api/servers/{quote(identifier, safe='')}/{action}"
            response = client.get(url) if action == "events" else client.post(url)
            assert response.status_code == 404
    assert runner.calls == []


@pytest.mark.parametrize("action", ["start", "stop", "restart", "backup"])
def test_real_fixed_argv(manifest, action):
    runner = RecordingRunner(manifest)
    with TestClient(create_app(RealAdapter(manifest, runner))) as client:
        response = client.post(
            f"/api/servers/survival/{action}",
            json={"unit": "sshd.service", "argv": ["sh", "-c", "touch pwned"]},
        )
        assert response.status_code == 200
    unit = next(server.unit for server in manifest.servers if server.id == "survival")
    expected = (
        ["games-backup", "survival"]
        if action == "backup"
        else ["systemctl", action, "--", unit]
    )
    assert runner.calls == [(expected, 2460), (["games-status"], 60)]


@pytest.mark.parametrize("mode", ["mock", "real"])
def test_disabled_prerequisites_and_backups(manifest_data, mode):
    server = manifest_data["servers"][0]
    server["backup"]["enabled"] = False
    manifest = Manifest.model_validate(manifest_data)
    runner = RecordingRunner(manifest)
    adapter = RealAdapter(manifest, runner) if mode == "real" else MockAdapter(manifest)
    with TestClient(create_app(adapter)) as client:
        assert client.post(f"/api/servers/{server['id']}/backup").status_code == 409
    server["available"] = False
    manifest = Manifest.model_validate(manifest_data)
    adapter = RealAdapter(manifest, runner) if mode == "real" else MockAdapter(manifest)
    with TestClient(create_app(adapter)) as client:
        assert client.post(f"/api/servers/{server['id']}/start").status_code == 409
    assert runner.calls == []


def test_status_inventory_mismatch_and_sanitized_helper_failure(manifest):
    runner = RecordingRunner(manifest)
    runner.status[0]["id"] = "sshd"
    with TestClient(create_app(RealAdapter(manifest, runner))) as client:
        response = client.get("/api/servers")
        assert response.status_code == 502
        assert response.json() == {"detail": "invalid status helper response"}


def test_sse_framing_and_real_log_cleanup(manifest):
    runner = RecordingRunner(manifest)

    async def check():
        stream = sse_events(RealAdapter(manifest, runner), "survival")
        frame = await anext(stream)
        assert frame.startswith("event: log\ndata: ") and frame.endswith("\n\n")
        entry = json.loads(frame.split("data: ")[1])
        assert entry["id"] == "survival" and entry["line"] == "journal line"
        await stream.aclose()

    asyncio.run(check())
    assert runner.calls == [(["games-logs", "survival", "--follow"], None)]
    assert runner.closed


def test_mock_sse_includes_action_logs(manifest):
    async def check():
        adapter = MockAdapter(manifest)
        await adapter.action("survival", "backup")
        stream = sse_events(adapter, "survival")
        assert "Mock console connected" in await anext(stream)
        assert "Mock backup #1 completed" in await anext(stream)
        await stream.aclose()

    asyncio.run(check())


def test_runner_executes_without_shell_and_reaps(monkeypatch):
    calls = []

    class Process:
        returncode = None

        async def communicate(self):
            self.returncode = 0
            return b"[]", None

    async def spawn(*argv, **kwargs):
        calls.append((argv, kwargs))
        return Process()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", spawn)
    assert asyncio.run(Runner().run(["games-status"], timeout=60)) == b"[]"
    assert calls[0][0] == ("games-status",)
    assert "shell" not in calls[0][1]
    assert calls[0][1]["start_new_session"] is True


def test_runner_sanitizes_failure(monkeypatch):
    class Process:
        returncode = 1

        async def communicate(self):
            return b"secret command output", None

    async def spawn(*argv, **kwargs):
        return Process()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", spawn)
    with pytest.raises(HelperFailure, match="^game helper failed$"):
        asyncio.run(Runner().run(["games-status"], timeout=60))


def test_configured_mock_uses_exact_generated_manifest(monkeypatch, manifest_data):
    monkeypatch.setenv("GAMES_DASHBOARD_MOCK", "1")
    adapter = configured_adapter()
    assert isinstance(adapter, MockAdapter)
    assert adapter.manifest.model_dump(mode="json") == manifest_data


def test_real_mode_does_not_fall_back(monkeypatch):
    from pathlib import Path

    monkeypatch.setenv("GAMES_DASHBOARD_MOCK", "0")

    def missing(path):
        assert str(path) == "/etc/games/manifest.json"
        raise FileNotFoundError("missing real manifest")

    monkeypatch.setattr(Path, "read_text", missing)
    with pytest.raises(FileNotFoundError):
        configured_adapter()

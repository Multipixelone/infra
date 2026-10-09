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


def test_datapack_inventory_is_optional_and_survives_sleep(manifest_data):
    for server in manifest_data["servers"]:
        server.pop("datapacks", None)
    older = Manifest.model_validate(manifest_data)
    assert all(server.datapacks == [] for server in older.servers)
    survival = next(server for server in manifest_data["servers"] if server["id"] == "survival")
    packs = [{"name": "Coordinates HUD", "version": "1.2.19", "installed": True}]
    survival["datapacks"] = packs
    manifest = Manifest.model_validate(manifest_data)
    with TestClient(create_app(MockAdapter(manifest))) as client:
        client.post("/api/servers/survival/start")
        servers = client.get("/api/servers").json()["servers"]
        server = next(server for server in servers if server["id"] == "survival")
        assert server["status"]["state"] == "sleeping"
        assert server["datapacks"] == packs


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
        shared = data["sharedServices"][0]
        assert {
            key: value for key, value in shared.items() if key != "status"
        } == manifest.model_dump()["sharedServices"][0]
        assert shared["status"] == {
            "id": "velocity",
            "state": "running",
            "unitState": "active",
            "ready": True,
            "playersOnline": None,
            "available": True,
        }
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


def test_plugin_inventory_and_static_map_survive_sleep(manifest):
    with TestClient(create_app(MockAdapter(manifest))) as client:
        client.post("/api/servers/survival/start")
        data = client.get("/api/servers").json()
    survival = next(server for server in data["servers"] if server["id"] == "survival")
    assert survival["status"]["state"] == "sleeping"
    assert survival["mapUrl"] == "https://map.finnrut.is"
    plugins = {plugin["name"]: plugin for plugin in survival["plugins"]}
    assert plugins["BlueMap"] == {"name": "BlueMap", "version": "5.28", "installed": True}
    assert not plugins["DiscordSRV"]["installed"]
    velocity = next(service for service in data["sharedServices"] if service["id"] == "velocity")
    assert any(plugin["name"] == "MiniMOTD" and plugin["installed"] for plugin in velocity["plugins"])


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
        self.shared_status = [
            item.model_dump()
            for item in asyncio.run(MockAdapter(manifest).shared_statuses())
        ]
        self.closed = False

    async def run(self, argv, timeout):
        self.calls.append((argv, timeout))
        if argv == ["games-status"]:
            return json.dumps(self.status).encode()
        if argv == ["games-shared-status"]:
            return json.dumps(self.shared_status).encode()
        return b""

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


@pytest.mark.parametrize(
    "state,unit_state,ready",
    [
        ("running", "active", True),
        ("running", "activating", False),
        ("stopped", "inactive", False),
        ("failed", "failed", False),
        ("failed", "inactive", False),
    ],
)
def test_real_shared_status_enrichment(manifest, state, unit_state, ready):
    runner = RecordingRunner(manifest)
    runner.shared_status[0].update(state=state, unitState=unit_state, ready=ready)
    with TestClient(create_app(RealAdapter(manifest, runner))) as client:
        response = client.get("/api/servers")
        assert response.status_code == 200
        shared = response.json()["sharedServices"][0]
        assert shared["status"] == runner.shared_status[0]
        assert shared["status"]["playersOnline"] is None
        assert all("status" in item for item in response.json()["servers"])
    assert runner.calls == [(["games-status"], 60), (["games-shared-status"], 60)]


@pytest.mark.parametrize(
    "mutation",
    ["missing", "duplicate", "unexpected", "malformed", "sleeping", "wrong_type"],
)
def test_shared_status_inventory_rejects_drift(manifest, mutation):
    runner = RecordingRunner(manifest)
    if mutation == "missing":
        runner.shared_status = []
    elif mutation == "duplicate":
        runner.shared_status *= 2
    elif mutation == "unexpected":
        runner.shared_status[0]["id"] = "sshd"
    elif mutation == "malformed":
        del runner.shared_status[0]["ready"]
    elif mutation == "sleeping":
        runner.shared_status[0]["state"] = "sleeping"
    else:
        runner.shared_status = None
    with TestClient(create_app(RealAdapter(manifest, runner))) as client:
        response = client.get("/api/servers")
        assert response.status_code == 502
        assert response.json() == {"detail": "invalid shared status helper response"}


@pytest.mark.parametrize("mode", ["mock", "real"])
def test_empty_shared_inventory(manifest_data, mode):
    manifest_data["sharedServices"] = []
    manifest = Manifest.model_validate(manifest_data)
    runner = RecordingRunner(manifest)
    adapter = MockAdapter(manifest) if mode == "mock" else RealAdapter(manifest, runner)
    with TestClient(create_app(adapter)) as client:
        response = client.get("/api/servers")
        assert response.status_code == 200
        assert response.json()["sharedServices"] == []
    assert all(argv != ["games-shared-status"] for argv, _ in runner.calls)


def test_mock_unavailable_shared_service(manifest_data):
    manifest_data["sharedServices"][0]["available"] = False
    with TestClient(
        create_app(MockAdapter(Manifest.model_validate(manifest_data)))
    ) as client:
        shared = client.get("/api/servers").json()["sharedServices"][0]
        assert shared["status"]["available"] is False
        assert shared["status"]["ready"] is False
        assert shared["status"]["state"] == "stopped"


@pytest.mark.parametrize("mutation", ["argv", "unit", "id", "duplicate", "collision"])
def test_shared_manifest_rejects_drift(manifest_data, mutation):
    shared = manifest_data["sharedServices"][0]
    if mutation == "argv":
        shared["logsCommand"] = ["sh", "-c", "games-logs velocity"]
    elif mutation == "unit":
        shared["unit"] = "--user"
    elif mutation == "id":
        shared["id"] = "$(id)"
    elif mutation == "duplicate":
        manifest_data["sharedServices"].append(shared.copy())
    else:
        shared["id"] = manifest_data["servers"][0]["id"]
        shared["logsCommand"] = ["games-logs", shared["id"]]
    with pytest.raises(ValidationError):
        Manifest.model_validate(manifest_data)


def test_shared_helper_failure_is_sanitized(manifest):
    class FailingRunner(RecordingRunner):
        async def run(self, argv, timeout):
            if argv == ["games-shared-status"]:
                raise HelperFailure("game helper failed")
            return await super().run(argv, timeout)

    with TestClient(
        create_app(RealAdapter(manifest, FailingRunner(manifest)))
    ) as client:
        response = client.get("/api/servers")
        assert response.status_code == 502
        assert response.json() == {"detail": "game helper failed"}

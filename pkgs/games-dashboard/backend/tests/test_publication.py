"""Production additions, without host controls or real credentials."""

from fastapi.testclient import TestClient
from games_dashboard.adapters import MockAdapter
from games_dashboard.app import create_app


def test_health_and_static_api_separation(manifest, tmp_path):
    (tmp_path / "index.html").write_text("<html>packaged dashboard</html>")
    (tmp_path / "assets").mkdir()
    (tmp_path / "assets" / "app.js").write_text("console.log('fixture')")
    with TestClient(create_app(MockAdapter(manifest), tmp_path)) as client:
        assert client.get("/healthz").json() == {"status": "ok"}
        assert "packaged dashboard" in client.get("/").text
        assert client.get("/assets/app.js").status_code == 200
        assert client.get("/api/not-a-route").status_code == 404
        assert (
            client.get("/api/not-a-route").headers["content-type"] == "application/json"
        )
        assert client.get("/missing-asset.js").status_code == 404


def test_production_origin_rejects_before_controls(manifest, monkeypatch):
    origin = "https://games.nyc.finnrut.is"
    monkeypatch.setenv("GAMES_DASHBOARD_ORIGIN", origin)
    adapter = MockAdapter(manifest)
    before = adapter.state["survival"].model_copy()
    with TestClient(create_app(adapter)) as client:
        for headers in ({}, {"Origin": "https://evil.example"}, {"Origin": "null"}):
            assert (
                client.post("/api/servers/survival/stop", headers=headers).status_code
                == 403
            )
        assert adapter.state["survival"] == before
        assert (
            client.post(
                "/api/servers/survival/stop", headers={"Origin": origin}
            ).status_code
            == 200
        )
        assert client.get("/api/servers").status_code == 200
        assert (
            client.get(
                "/api/servers/survival/events",
                headers={"Origin": "https://evil.example"},
            ).status_code
            == 403
        )
        assert (
            client.options(
                "/api/servers/survival/stop", headers={"Origin": "https://evil.example"}
            ).status_code
            == 403
        )

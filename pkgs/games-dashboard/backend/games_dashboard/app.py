"""Small API shared by the mock and real development adapters."""

import asyncio
import contextlib
import json
import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from .adapters import (
    HelperFailure,
    MockAdapter,
    RealAdapter,
    Unavailable,
    UnknownServer,
)
from .models import Manifest


def configured_adapter():
    mode = os.environ.get("GAMES_DASHBOARD_MOCK", "0")
    if mode not in {"0", "1"}:
        raise ValueError("GAMES_DASHBOARD_MOCK must be 0 or 1")
    if mode == "1":
        filename = os.environ.get("GAMES_DASHBOARD_MOCK_MANIFEST")
        if not filename:
            raise ValueError("enter the games-dashboard Nix shell for the mock fixture")
        manifest = Manifest.model_validate_json(Path(filename).read_text())
        return MockAdapter(manifest)
    manifest = Manifest.model_validate_json(
        Path("/etc/games/manifest.json").read_text()
    )
    return RealAdapter(manifest)


async def sse_events(adapter, identifier):
    """Heartbeats keep quiet real journals alive; cancellation closes the helper."""
    events = adapter.events(identifier)
    pending = None
    try:
        while True:
            if pending is None:
                pending = asyncio.create_task(anext(events))
            done, _ = await asyncio.wait({pending}, timeout=10)
            if not done:
                yield ": heartbeat\n\n"
                continue
            completed = pending
            pending = None
            try:
                entry = completed.result()
            except StopAsyncIteration:
                break
            except HelperFailure:
                yield 'event: error\ndata: {"detail":"log helper failed"}\n\n'
                break
            yield f"event: log\ndata: {json.dumps(entry)}\n\n"
    finally:
        if pending is not None:
            pending.cancel()
            with contextlib.suppress(asyncio.CancelledError, StopAsyncIteration):
                await pending
        await events.aclose()


def create_app(adapter=None, static_directory=None):
    @asynccontextmanager
    async def lifespan(app):
        app.state.adapter = adapter if adapter is not None else configured_adapter()
        yield

    app = FastAPI(title="Games dashboard", lifespan=lifespan)
    origin = os.environ.get("GAMES_DASHBOARD_ORIGIN")

    @app.middleware("http")
    async def require_same_origin(request, call_next):
        if origin and request.url.path.startswith("/api/"):
            supplied = request.headers.get("origin")
            if (supplied is not None and supplied != origin) or (
                request.method == "POST" and supplied != origin
            ):
                return JSONResponse(
                    {"detail": "invalid request origin"}, status_code=403
                )
        return await call_next(request)

    @app.get("/healthz")
    async def health():
        return {"status": "ok"}

    for exception, code in (
        (UnknownServer, 404),
        (Unavailable, 409),
        (HelperFailure, 502),
    ):

        async def handle_error(request, error, status_code=code):
            return JSONResponse({"detail": str(error)}, status_code=status_code)

        app.add_exception_handler(exception, handle_error)

    @app.get("/api/servers")
    async def servers(request: Request):
        adapter = request.app.state.adapter
        statuses = {item.id: item for item in await adapter.statuses()}
        data = adapter.manifest.model_dump()
        data["servers"] = [
            server.model_dump() | {"status": statuses[server.id].model_dump()}
            for server in adapter.manifest.servers
        ]
        return data

    @app.get("/api/servers/{identifier}/events")
    async def events(identifier: str, request: Request):
        adapter = request.app.state.adapter
        adapter.server(identifier)
        return StreamingResponse(
            sse_events(adapter, identifier),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    # Separate literal routes keep the accepted action vocabulary fixed.
    def action_route(action):
        async def perform(identifier: str, request: Request):
            status = await request.app.state.adapter.action(identifier, action)
            return {"id": identifier, "action": action, "status": status.model_dump()}

        return perform

    for action in ("start", "stop", "restart", "backup"):
        app.add_api_route(
            f"/api/servers/{{identifier}}/{action}",
            action_route(action),
            methods=["POST"],
            name=action,
        )

    # Keep API misses JSON 404s, never static HTML, even in production.
    @app.api_route("/api/{path:path}", methods=["GET", "POST", "HEAD", "OPTIONS"])
    async def unknown_api(path: str):
        return JSONResponse({"detail": "Not Found"}, status_code=404)

    if static_directory is not None:
        app.mount(
            "/", StaticFiles(directory=static_directory, html=True), name="frontend"
        )

    return app


app = create_app()

"""Production entry point: one worker and a loopback-only listener."""

import argparse
from pathlib import Path

import uvicorn

from .app import create_app


def main():
    parser = argparse.ArgumentParser(description="Serve the private games dashboard")
    parser.add_argument("--port", type=int, default=8780)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error("port must be between 1024 and 65535")
    static = Path(__file__).parent / "static"
    if not (static / "index.html").is_file():
        parser.error("built frontend is missing; use the Nix package")
    # A single process owns the adapter's per-server operation locks.
    uvicorn.run(create_app(static_directory=static), host="127.0.0.1", port=args.port)

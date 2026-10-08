"""Supervise both reload servers against the editable checkout, without a shell."""

import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def stop(process):
    try:
        # An exited npm/reloader parent may still have live descendants.
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()


def main():
    root = Path.cwd()
    backend = root / "pkgs/games-dashboard/backend"
    frontend = root / "pkgs/games-dashboard/frontend"
    if not (backend / "games_dashboard/app.py").is_file():
        sys.exit("run games-dashboard-dev from the infra worktree root")
    if not (frontend / "node_modules/vite/bin/vite.js").is_file():
        sys.exit("first run: npm --prefix pkgs/games-dashboard/frontend ci")
    try:
        raw_port = os.environ.get("PORT", "5173")
        if not raw_port.isascii() or not raw_port.isdecimal():
            raise ValueError
        port = int(raw_port)
        if not 1024 <= port <= 65534:
            raise ValueError
    except ValueError:
        sys.exit("PORT must be an integer from 1024 through 65534")
    env = os.environ | {
        "PORT": str(port),
        "GAMES_DASHBOARD_MOCK": os.environ.get("GAMES_DASHBOARD_MOCK", "1"),
    }
    processes = []

    def interrupted(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    try:
        processes.append(
            subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "uvicorn",
                    "games_dashboard.app:app",
                    "--app-dir",
                    str(backend),
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(port + 1),
                    "--reload",
                    "--reload-dir",
                    str(backend),
                    "--reload-delay",
                    "0.1",
                    # A connected SSE client must not hold a dev reload open.
                    "--timeout-graceful-shutdown",
                    "0",
                ],
                env=env,
                start_new_session=True,
            )
        )
        processes.append(
            subprocess.Popen(
                ["npm", "run", "dev"],
                cwd=frontend,
                env=env,
                start_new_session=True,
            )
        )
        print(f"Games dashboard: http://127.0.0.1:{port}", flush=True)
        while all(process.poll() is None for process in processes):
            time.sleep(0.1)
        return next(
            process.returncode or 1
            for process in processes
            if process.returncode is not None
        )
    except KeyboardInterrupt:
        return 0
    finally:
        for process in reversed(processes):
            stop(process)


if __name__ == "__main__":
    sys.exit(main())

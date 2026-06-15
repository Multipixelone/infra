#!/usr/bin/env python3
"""Explo -> OpenClaw -> Telegram bridge.

Explo's HTTP_RECEIVER posts a fixed JSON payload to this loopback listener on
notable events (e.g. a playlist being created). OpenClaw has no generic inbound
webhook->message endpoint (only Gmail), so this shim translates the payload into
an `openclaw message send` call. Stdlib only; runs as the tunnel user service so
it can reach the OpenClaw gateway state under ~/.openclaw.

Env:
  EXPLO_NOTIFY_PORT  loopback port to listen on (default 18790)
  OPENCLAW_BIN       path to the openclaw wrapper (nodejs on PATH)
  OPENCLAW_TARGET    Telegram chat id / @username to deliver to (from agenix)

Example Explo payload:
  {"time":"...","level":"INFO","message":"playlist created successfully",
   "attributes":{"playlistName":"Weekly-Exploration","system":"subsonic"}}
"""

import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("EXPLO_NOTIFY_PORT", "18790"))
OPENCLAW_BIN = os.environ.get("OPENCLAW_BIN", "openclaw")
TARGET = os.environ.get("OPENCLAW_TARGET", "")


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def build_message(payload):
    """Return a Telegram message for a playlist-creation event, else None.

    We only text on successful playlist creation so other Explo notifications
    (warnings, per-track logs) don't spam the chat.
    """
    attrs = payload.get("attributes") or {}
    name = attrs.get("playlistName")
    message = (payload.get("message") or "").lower()
    if not name or "playlist created" not in message:
        return None
    system = attrs.get("system")
    suffix = f" ({system})" if system else ""
    return f'\U0001f3b5 Explo created playlist "{name}"{suffix}'


def deliver(text):
    if not TARGET:
        log("explo-notify: OPENCLAW_TARGET unset, dropping:", text)
        return
    subprocess.run(
        [
            OPENCLAW_BIN,
            "message",
            "send",
            "--channel",
            "telegram",
            "--target",
            TARGET,
            "--message",
            text,
        ],
        check=True,
    )


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 (stdlib API)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        # Always 200 so Explo doesn't retry/queue on our account.
        self.send_response(200)
        self.end_headers()
        try:
            payload = json.loads(raw.decode("utf-8")) if raw else {}
        except (ValueError, UnicodeDecodeError):
            log("explo-notify: non-JSON body, ignoring")
            return
        try:
            text = build_message(payload)
            if text:
                deliver(text)
                log("explo-notify: delivered:", text)
        except subprocess.CalledProcessError as exc:
            log("explo-notify: openclaw send failed:", exc)

    def log_message(self, *args):  # silence default stderr access log
        pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    log(f"explo-notify: listening on 127.0.0.1:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()

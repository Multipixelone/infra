from __future__ import annotations

import json
import os
import sys

from .config import TrustedConfig, production_factory
from .errors import Configuration, MusicError
from .input import MAX_INPUT, load_json, parse
from .models import now
from .resolver import MusicBrainzClient, Resolver

COMMANDS = {"resolve", "submit", "choose", "status", "retry", "worker"}


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    operation = argv[0] if len(argv) == 1 else ""
    try:
        if operation not in COMMANDS:
            raise Configuration("fixed subcommand required")
        raw = sys.stdin.buffer.read(MAX_INPUT + 1)
        request = parse(operation, load_json(raw))
        if operation == "resolve":
            user_agent = os.environ.get("OPENCLAW_MUSIC_MB_USER_AGENT")
            if not user_agent:
                raise Configuration("resolve requires OPENCLAW_MUSIC_MB_USER_AGENT")
            result = Resolver(
                MusicBrainzClient(
                    user_agent,
                    os.environ.get(
                        "OPENCLAW_MUSIC_MB_BASE_URL", "https://musicbrainz.org/ws/2"
                    ),
                )
            ).resolve(request, None, now())
            output = {"schema": 1, "operation": "resolve", **result}
        else:
            config = TrustedConfig.from_env()
            service = production_factory(config)
            if operation == "submit":
                output = service.submit(request)
            elif operation == "choose":
                output = service.choose(**request)
            elif operation == "status":
                output = service.status(**request)
            elif operation == "retry":
                output = service.retry(**request)
            else:
                output = service.worker_once()
        status = 0
    except MusicError as exc:
        output = {
            "schema": 1,
            "operation": operation or "invalid",
            "state": "error",
            "error": {"code": exc.symbol, "message": exc.message},
            "retryable": exc.retryable,
        }
        status = exc.code
    except Exception:  # noqa: BLE001 - final JSON boundary must not leak internals
        output = {
            "schema": 1,
            "operation": operation or "invalid",
            "state": "error",
            "error": {"code": "internal_error", "message": "internal failure"},
            "retryable": False,
        }
        status = 6
    sys.stdout.write(json.dumps(output, separators=(",", ":")) + "\n")
    return status


if __name__ == "__main__":
    raise SystemExit(main())

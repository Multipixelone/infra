from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from .config import TrustedConfig, _absolute, production_factory
from .errors import Configuration, MusicError
from .input import MAX_INPUT, load_json, parse
from .jobs import public
from .ledger import Ledger
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
        elif operation == "status":
            # Read-only status must remain available when retrieval credentials are
            # absent, and it must not rewrite legacy records.
            ledger_root = _absolute(os.environ.get("OPENCLAW_MUSIC_LEDGER"), "ledger")
            if not Path(ledger_root).is_dir():
                raise Configuration("ledger is unavailable")
            ledger = Ledger(ledger_root)
            output = public(ledger.get(request["job_id"]), "status")
        else:
            config = TrustedConfig.from_env()
            service = production_factory(config)
            if operation == "submit":
                output = service.submit(request)
            elif operation == "choose":
                output = service.choose(**request)
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

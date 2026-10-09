"""Read-only shared-service status using the existing runtime helpers."""

import argparse
import importlib.util
import json
from pathlib import Path


def status(runtime, cfg, identifier, item):
    unit = runtime.unit_state(cfg, item)
    failed = (
        unit.get("ActiveState") == "failed"
        or unit.get("SubState") == "failed"
        or unit.get("Result", "success") not in ("", "success", "missing-secrets")
    )
    active = unit.get("ActiveState") in ("active", "activating", "reloading")
    port = item.get("serverPort")
    ready = bool(
        item["available"]
        and not failed
        and unit.get("ActiveState") in ("active", "reloading")
        and port is not None
        and runtime.passive_listening(port)
    )
    return {
        "id": identifier,
        "state": "failed" if failed else "running" if active else "stopped",
        "unitState": unit.get("ActiveState"),
        "ready": ready,
        "playersOnline": None,
        "available": item["available"],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--runtime", required=True)
    args = parser.parse_args()
    cfg = json.loads(Path(args.inventory).read_text())
    spec = importlib.util.spec_from_file_location("games_runtime", args.runtime)
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    print(
        json.dumps(
            [status(runtime, cfg, "velocity", cfg["proxy"])] if cfg["proxy"] else []
        )
    )


if __name__ == "__main__":
    main()

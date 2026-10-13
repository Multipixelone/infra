"""Fake the documented CLI at its normal path, only inside the NixOS test VM."""

import json
import os
import pwd
import sys
import time
from pathlib import Path

state = Path.home() / ".openclaw"
assert os.getuid() == os.geteuid() == pwd.getpwnam("tunnel").pw_uid != 0
assert Path.home() == Path("/home/tunnel")
assert Path.cwd() == Path.home()
assert os.environ["OPENCLAW_STATE_DIR"] == str(state)
assert not os.access("/var/lib/openclaw-nixos-activate/approved", os.R_OK)
assert not any(
    "openclaw-nixos-activate" in os.readlink(fd)
    for fd in Path("/proc/self/fd").iterdir()
    if fd.exists()
)
# Read a random runtime credential the way a CLI would; it must never be an arg.
token = json.loads((state / "openclaw.json").read_text())["gateway"]["auth"]["token"]
assert all(token not in arg for arg in sys.argv)
assert "--token" not in sys.argv and "--password" not in sys.argv
assert "--url" not in sys.argv
with (state / "events.jsonl").open("a") as output:
    output.write(json.dumps({"uid": os.getuid(), "argv": sys.argv[1:]}) + "\n")
# Approval must suppress sensitive diagnostics and non-metadata JSON fields.
print(token, file=sys.stderr, flush=True)
behavior = (state / "fixture-behavior").read_text().strip()
if behavior == "slow":
    time.sleep(11)
if behavior == "malformed":
    print(token, flush=True)
elif behavior != "missing":
    outcome = "failed" if behavior == "fail" else behavior
    if outcome not in ("failed", "partial_failed", "suppressed", "no_visible_payload"):
        outcome = "sent"
    delivery: dict[str, object] = {
        "requested": True,
        "attempted": outcome != "no_visible_payload",
        "status": "suppressed" if outcome == "no_visible_payload" else outcome,
        "succeeded": "partial"
        if outcome == "partial_failed"
        else outcome not in ("failed",),
    }
    if outcome == "failed":
        delivery.update(error=True, errorMessage=token)
    elif outcome == "partial_failed":
        delivery.update(
            error=True, errorMessage=token, resultCount=1, sentBeforeError=True
        )
    else:
        delivery["resultCount"] = 1 if outcome == "sent" else 0
        if outcome == "no_visible_payload":
            delivery["reason"] = "no_visible_payload"
        elif outcome == "suppressed":
            delivery["reason"] = token
    print(
        json.dumps(
            {
                "status": "ok",
                "deliveryStatus": delivery,
                "result": {"deliveryStatus": delivery, "payloads": [{"text": token}]},
            }
        ),
        flush=True,
    )
if behavior == "fail":
    sys.exit(1)

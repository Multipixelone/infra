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
# Approval must suppress even a failing CLI's sensitive diagnostic output.
print(token, flush=True)
print(token, file=sys.stderr, flush=True)
behavior = (state / "fixture-behavior").read_text().strip()
if behavior == "hang":
    (state / "hung-pid").write_text(str(os.getpid()))
    time.sleep(60)
if behavior == "fail":
    sys.exit(1)

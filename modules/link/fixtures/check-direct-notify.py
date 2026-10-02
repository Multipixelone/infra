"""Run generated applications offline, replacing only their runtime tool PATH."""

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from alert_format_contract import check_message


def application_body(path):
    # writeShellApplication prepends its package PATH. Remove just that line
    # so the actual generated application executes against strict tool mocks.
    return re.sub(r"^export PATH=.*$", "", Path(path).read_text(), flags=re.MULTILINE)


mock = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
if tool == "date":
    if args == ["+%s"]:
        print(os.environ["EPOCH"])
    else:
        os.execv(os.environ["REAL_DATE"], [os.environ["REAL_DATE"], *args])
elif tool == "journalctl":
    assert args == ["-u", "fixture.service", "-n", "15", "--no-pager", "-o", "cat"], args
    print("Journal evidence " + "x" * 4000)
elif tool == "id":
    print("1000")
elif tool == "runuser":
    if "--property=ActiveState" in args:
        print("active")
    else:
        print("0")
elif tool == "curl":
    url = next(arg for arg in args if arg.startswith("http"))
    if url == "http://127.0.0.1:18789/health":
        print(os.environ["HEALTH"])
    else:
        assert url == "https://api.telegram.org/botoffline-test-only/sendMessage", url
        assert "chat_id=-1" in args, args
        message = next(arg[5:] for arg in args if arg.startswith("text="))
        Path(os.environ["MESSAGE"]).write_text(message)
        print('{"ok":true}')
else:
    raise AssertionError(tool)
"""

with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    tools = root / "bin"
    tools.mkdir()
    for tool in ["curl", "journalctl", "date", "runuser", "id"]:
        path = tools / tool
        path.write_text(mock.replace("#!/usr/bin/env python3", f"#!{sys.executable}"))
        path.chmod(0o755)
    env = {
        **os.environ,
        "PATH": str(tools) + ":" + os.environ["PATH"],
        "REAL_DATE": subprocess.check_output(
            ["bash", "-c", "command -v date"], text=True
        ).strip(),
        "MESSAGE": str(root / "message"),
        "TELEGRAM_BOT_TOKEN": "offline-test-only",
        "TELEGRAM_CHAT_ID": "-1",
    }
    direct = root / "direct.sh"
    direct.write_text(application_body(sys.argv[1]))
    for epoch, expected in [
        ("1790555760", "2026-09-27 20:36 EDT"),
        ("1767227760", "2025-12-31 19:36 EST"),
    ]:
        env["EPOCH"] = epoch
        subprocess.run(
            ["bash", "-euo", "pipefail", str(direct), "fixture.service"],
            env=env,
            check=True,
        )
        message = (root / "message").read_text()
        check_message(
            message,
            "OptedInUnitFailed",
            "fixture.service on zelda",
            "firing",
            since=expected,
        )
        assert (
            "Journal:\n" in message
            and len(message.split("Journal:\n")[1].encode()) <= 2000
        )
        assert len(message) < 4096
    # Exercise the shared dead-man renderer with identical persisted epochs.
    for status in ["firing", "resolved"]:
        message = subprocess.check_output(
            [
                "bash",
                "-euo",
                "pipefail",
                "-c",
                'source "$1"; render_alert "$2" ExampleAlert example-target 1767227760 1767378000 "Example summary" "Example hint"',
                "offline",
                sys.argv[3],
                status,
            ],
            env=env,
            text=True,
        )
        check_message(
            message,
            "ExampleAlert",
            "example-target",
            status,
            since="2025-12-31 19:36 EST",
        )
    metrics_dir = root / "metrics"
    metrics_dir.mkdir()
    gateway = root / "gateway.sh"
    gateway.write_text(
        application_body(sys.argv[2]).replace(
            "/var/lib/prometheus-node-exporter-text-files", str(metrics_dir)
        )
    )
    for health, value in [
        (' {"ok":true,"private":"never-export"}', "1"),
        ('{"ok":false}', "0"),
        ("invalid JSON", "0"),
    ]:
        env["HEALTH"] = health
        subprocess.run(["bash", "-euo", "pipefail", str(gateway)], env=env, check=True)
        metrics = (metrics_dir / "openclaw.prom").read_text()
        assert f"openclaw_gateway_healthy {value}\n" in metrics
        assert "openclaw_gateway_active 1\n" in metrics
        assert (
            f"openclaw_metrics_last_update_timestamp_seconds {env['EPOCH']}\n"
            in metrics
        )
        assert (
            "never-export" not in metrics
            and not (metrics_dir / "openclaw.prom.tmp").exists()
        )
print(
    "direct notifier, shared renderer, journal bounds and atomic gateway health/freshness metrics passed offline"
)

"""Offline timer contracts; every network and system-unit call is stubbed."""

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

script = Path(sys.argv[1]).resolve()
formatter = Path(sys.argv[2]).resolve()
from alert_format_contract import check_message

mock = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
case = json.loads(Path(os.environ["CASE"]).read_text())
args = sys.argv[1:]
if Path(sys.argv[0]).name == "systemctl":
    assert args[:3] == ["--system", "is-active", "--quiet"], args
    sys.exit(0 if case.get(args[3], True) else 1)
url = next(arg for arg in args if arg.startswith("http"))
with open(os.environ["CALLS"], "a") as calls:
    calls.write(url + "\\n")
if url.startswith("https://api.telegram.org/"):
    text = next(arg[5:] for arg in args if arg.startswith("text="))
    with open(os.environ["ATTEMPTS"], "a") as output:
        output.write(json.dumps(text) + "\\n")
    if case.get("delivery", True):
        with open(os.environ["DELIVERED"], "a") as output:
            output.write(json.dumps(text) + "\\n")
        print('{"ok":true}')
    else:
        print('{"ok":false}')
    sys.exit(0)
responses = {
    "http://127.0.0.1:9093/-/healthy": ("health", "OK"),
    "http://127.0.0.1:9090/api/v1/query": ("discovery", json.dumps({
        "status": "success", "data": {"resultType": "vector", "result": [
            {"value": [1, "1"]}]}})),
    "http://127.0.0.1:9093/metrics": ("metrics",
        'alertmanager_notifications_failed_total{integration="telegram",reason="other"} 0\\n'),
}
assert url in responses, url
key, default = responses[url]
response = case.get(key, default)
if response is None:
    sys.exit(7)
print(response)
"""


class Timer:
    def __init__(self, root):
        self.root = root
        self.state = root / "state"
        self.env = {
            **os.environ,
            "PATH": str(root / "bin") + ":" + os.environ["PATH"],
            "STATE_DIRECTORY": str(self.state),
            "CASE": str(root / "case.json"),
            "CALLS": str(root / "calls"),
            "ATTEMPTS": str(root / "attempts"),
            "DELIVERED": str(root / "delivered"),
            "TELEGRAM_BOT_TOKEN": "offline-test-only",
            "TELEGRAM_CHAT_ID": "-1",
        }
        (root / "bin").mkdir(parents=True)
        for tool in ["curl", "systemctl"]:
            path = root / "bin" / tool
            path.write_text(
                mock.replace("#!/usr/bin/env python3", f"#!{sys.executable}")
            )
            path.chmod(0o755)

    def run(self, **case):
        (self.root / "case.json").write_text(json.dumps(case))
        result = subprocess.run(
            [
                "bash",
                "-euo",
                "pipefail",
                "-c",
                'source "$1"; source "$2"',
                "offline",
                str(formatter),
                str(script),
            ],
            env=self.env,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stderr

    def messages(self, file="delivered"):
        path = self.root / file
        return (
            [json.loads(line) for line in path.read_text().splitlines()]
            if path.exists()
            else []
        )

    def pending(self):
        return sorted((self.state / "pending").glob("*.txt"))


def discovery(value):
    return json.dumps(
        {
            "status": "success",
            "data": {"resultType": "vector", "result": [{"value": [1, value]}]},
        }
    )


def metrics(first, second=0):
    # Different label order and reasons, plus an unrelated integration.
    return (
        f'alertmanager_notifications_failed_total{{integration="telegram",reason="other"}} {first}\n'
        f'alertmanager_notifications_failed_total{{reason="timeout",integration="telegram"}} {second}\n'
        'alertmanager_notifications_failed_total{integration="email",reason="other"} 999\n'
    )


with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    timer = Timer(root / "healthy")
    for _ in range(5):
        timer.run()
    assert not timer.messages() and not timer.pending()

    failures = [
        ("alertmanager.service", False, "alertmanager.service is not active"),
        ("prometheus.service", False, "prometheus.service is not active"),
        ("health", None, "Alertmanager /-/healthy"),
        (
            "discovery",
            discovery("0"),
            "Prometheus reports zero discovered Alertmanagers",
        ),
        (
            "discovery",
            None,
            "Prometheus loopback Alertmanager discovery API is unreachable",
        ),
        ("discovery", "invalid JSON", "discovery metric is missing or invalid"),
        ("discovery", discovery("NaN"), "discovery metric is missing or invalid"),
        (
            "discovery",
            '{"status":"success","data":{"resultType":"vector","result":[]}}',
            "discovery metric is missing or invalid",
        ),
        ("metrics", None, "failure metrics cannot be read"),
        ("metrics", "# missing Telegram samples", "failure metrics cannot be read"),
        ("metrics", metrics("NaN"), "failure metrics cannot be read"),
    ]
    for index, (key, value, expected) in enumerate(failures):
        timer = Timer(root / f"failure-{index}")
        for _ in range(2):
            timer.run(**{key: value})
            assert not timer.messages()
        for _ in range(3):
            timer.run(**{key: value})
        assert len(timer.messages()) == 1, timer.messages()
        assert expected in timer.messages()[0]
        check_message(
            timer.messages()[0],
            "AlertingPipelineDown",
            "alerting pipeline on link",
            "firing",
        )
        timer.run()
        timer.run()
        assert len(timer.messages()) == 2 and timer.messages()[1].startswith("✅")

    timer = Timer(root / "counters")
    timer.run(metrics=metrics(10, 20))  # first sample is a baseline
    timer.run(metrics=metrics(10, 20))
    for value in [21, 22, 23, 24]:
        timer.run(metrics=metrics(10, value))
    assert len(timer.messages()) == 1
    assert "notification failures increased from 32 to 33" in timer.messages()[0]
    timer.run(metrics=metrics(10, 24))
    timer.run(metrics=metrics(0, 0))  # a reset is healthy, not a failure
    assert len(timer.messages()) == 2
    timer.run(metrics=metrics(0, 1))
    timer.run(metrics=metrics(0, 1))  # isolated increases do not meet debounce
    assert len(timer.messages()) == 2

    timer = Timer(root / "independent")
    broken = {
        "alertmanager.service": False,
        "prometheus.service": False,
        "health": None,
        "discovery": None,
        "metrics": None,
        "delivery": False,
    }
    for _ in range(5):
        timer.run(**broken)
    assert len(timer.pending()) == 1
    calls = (timer.root / "calls").read_text().splitlines()
    for url in [
        "http://127.0.0.1:9093/-/healthy",
        "http://127.0.0.1:9090/api/v1/query",
        "http://127.0.0.1:9093/metrics",
    ]:
        assert calls.count(url) == 5
    # Recovery while delivery is broken must retain BOTH transitions in order.
    timer.run(delivery=False)
    assert len(timer.pending()) == 2 and not timer.messages()
    timer.run()
    timer.run()
    assert not timer.pending() and len(timer.messages()) == 2
    check_message(
        timer.messages()[0],
        "AlertingPipelineDown",
        "alerting pipeline on link",
        "firing",
    )
    check_message(
        timer.messages()[1],
        "AlertingPipelineDown",
        "alerting pipeline on link",
        "resolved",
    )
    timer.run()
    assert len(timer.messages()) == 2

    timer = Timer(root / "missing-credentials")
    timer.env.pop("TELEGRAM_BOT_TOKEN")
    timer.env.pop("TELEGRAM_CHAT_ID")
    for _ in range(3):
        stderr = timer.run(**{"alertmanager.service": False})
    assert len(timer.pending()) == 1 and not timer.messages("attempts")
    assert "credentials unavailable" in stderr
    timer.run()  # retain recovery, too
    timer.env.update(TELEGRAM_BOT_TOKEN="offline-test-only", TELEGRAM_CHAT_ID="-1")
    timer.run()
    assert len(timer.messages()) == 2 and not timer.pending()

    # Changes in broken checks must not close/reopen an existing incident.
    timer = Timer(root / "overlap")
    for _ in range(3):
        timer.run(**{"alertmanager.service": False})
    timer.run(**{"prometheus.service": False})
    timer.run(**{"prometheus.service": False})
    assert len(timer.messages()) == 1
    timer.run()
    assert len(timer.messages()) == 2

    # Obsolete state and queued gateway messages are retired exactly once.
    timer = Timer(root / "legacy")
    (timer.state / "pending").mkdir(parents=True)
    (timer.state / "pending" / "old.txt").write_text("obsolete gateway failure")
    (timer.state / "alerted").touch()
    (timer.state / "fail_count").write_text("100")
    timer.run()
    assert not timer.pending() and not timer.messages()
    assert not (timer.state / "alerted").exists()
    assert not (timer.state / "fail_count").exists()
    assert "18789" not in (timer.root / "calls").read_text()

print(
    "dead-man: debounce, consolidated failures, recovery, legacy-state retirement, counter resets, missing secrets and durable delivery retries passed (offline)"
)

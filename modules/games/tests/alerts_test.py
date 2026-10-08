"""Generate promtool boundary scenarios from the shipped game rules."""

import json
import re
import sys
from pathlib import Path

rule_file = sys.argv[1]
rules = json.loads(Path(rule_file).read_text())["groups"][0]["rules"]
by_name = {rule["alert"]: rule for rule in rules if "alert" in rule}
base = {
    "job": "link-node",
    "instance": "link",
    "host": "link",
    "server_id": "survival",
    "game": "minecraft-paper",
    "unit": "minecraft-server-survival.service",
}


def series(name, labels, values):
    suffix = ",".join(
        f"{key}={json.dumps(value)}" for key, value in sorted(labels.items())
    )
    return {"series": name + "{" + suffix + "}", "values": values}


def expectation(name, labels):
    rule = by_name[name]
    return {
        "exp_labels": labels | rule["labels"],
        "exp_annotations": {
            key: re.sub(
                r"{{\s*\$labels\.(\w+)\s*}}", lambda match: labels[match[1]], value
            )
            for key, value in rule["annotations"].items()
        },
    }


def scenario(
    name,
    *,
    identifier="survival",
    enabled=1,
    success=1,
    failed=0,
    ready=1,
    memory=0,
    backup=False,
    configured=1,
    backup_failed=0,
    last_success=0,
    enabled_since=1,
    count=30,
    expected=None,
    checks=None,
):
    labels = base | (
        {
            "server_id": "velocity",
            "game": "minecraft-velocity",
            "unit": "minecraft-server-velocity.service",
        }
        if identifier == "velocity"
        else {}
    )
    inputs = [
        series(metric, labels, f"{value}x{count}")
        for metric, value in (
            ("games_server_enabled", enabled),
            ("games_metrics_collection_success", success),
            ("games_server_failed", failed),
            ("games_server_ready", ready),
        )
    ]
    inputs += [
        series(
            "games_metrics_last_update_timestamp_seconds",
            {"host": "link", "job": "link-node", "instance": "link"},
            f"0+60x{count}",
        ),
        series("up", {"job": "link-node", "instance": "link"}, f"1x{count}"),
        series(
            "games_memory_current_bytes",
            labels | {"scope": "server"},
            f"{memory}x{count}",
        ),
        series(
            "games_memory_limit_bytes", labels | {"scope": "server"}, f"100x{count}"
        ),
    ]
    if backup:
        backup_labels = labels | {"unit": "restic-backups-games-survival.service"}
        inputs += [
            series(metric, backup_labels, f"{value}x{count}")
            for metric, value in (
                ("games_backup_configured", configured),
                ("games_backup_failed", backup_failed),
                ("games_backup_last_success_timestamp_seconds", last_success),
                ("games_backup_enabled_timestamp_seconds", enabled_since),
            )
        ]
        expected_labels = backup_labels
    else:
        expected_labels = labels | (
            {"scope": "server"} if expected == "GameServerMemoryPressure" else {}
        )
    assertions = []
    for at, fire in checks or [("4m", False), ("5m", True)]:
        for alert_name in by_name:
            assertions.append(
                {
                    "eval_time": at,
                    "alertname": alert_name,
                    "exp_alerts": [expectation(alert_name, expected_labels)]
                    if fire and alert_name == expected
                    else [],
                }
            )
    return {
        "name": name,
        "interval": "1m",
        "input_series": inputs,
        "alert_rule_test": assertions,
    }


tests = [
    scenario("confirmed crash", failed=1, expected="GameServerFailed"),
    scenario("normal sleep", ready=0, expected=None),
    scenario("intentional clean stop", ready=0, expected=None),
    scenario(
        "disabled and missing secret", enabled=0, failed=1, ready=0, expected=None
    ),
    scenario("unknown state collection", success=0, failed=1, expected=None),
    scenario(
        "proxy down owns its failure",
        identifier="velocity",
        failed=1,
        ready=0,
        expected="VelocityDown",
    ),
    scenario("proxy healthy", identifier="velocity", expected=None),
    scenario(
        "sustained memory pressure",
        memory=91,
        expected="GameServerMemoryPressure",
        checks=[("14m", False), ("15m", True)],
    ),
    scenario(
        "memory boundary is strictly over ninety percent",
        memory=90,
        expected=None,
        checks=[("20m", False)],
    ),
    scenario(
        "backup failure", backup=True, backup_failed=1, expected="GameBackupUnhealthy"
    ),
    scenario(
        "disabled backups never page",
        backup=True,
        backup_failed=1,
        configured=0,
        count=3000,
        expected=None,
        checks=[("49h", False)],
    ),
    scenario(
        "first backup grace then stale",
        backup=True,
        count=3000,
        expected="GameBackupUnhealthy",
        checks=[("48h", False), ("48h5m", False), ("48h6m", True)],
    ),
    scenario(
        "successful backup freshness",
        backup=True,
        last_success=80000,
        count=3000,
        expected=None,
        checks=[("49h", False)],
    ),
]
# Stale monitoring must not invent a game failure.
stale = scenario("stale telemetry", failed=1, expected=None, checks=[("10m", False)])
for item in stale["input_series"]:
    if item["series"].startswith("games_metrics_last_update_timestamp_seconds"):
        item["values"] = "0x30"
tests.append(stale)
recovered = scenario(
    "failed attempt followed by successful retry",
    backup=True,
    expected=None,
    checks=[("10m", False)],
)
for item in recovered["input_series"]:
    if item["series"].startswith("games_backup_failed"):
        item["values"] = "1x1 0x29"
tests.append(recovered)
Path(sys.argv[2]).write_text(
    json.dumps(
        {"rule_files": [rule_file], "evaluation_interval": "30s", "tests": tests}
    )
)

"""Test shipped rules against evaluated opt-ins, with bounded synthetic series."""

import json
import re
import sys
from urllib.parse import quote_plus

import yaml

with open(sys.argv[1]) as source:
    contract = json.load(source)
inventory = contract["inventory"]
helper = contract["helperFixture"]
assert helper["units"] == ["fixture.service", "fixture.socket", "fixture@.service"]
for unit in ["fixture.service", "fixture.socket", "fixture@instance.service"]:
    assert re.fullmatch(helper["regex"], unit), unit
for unit in [
    "disabled.service",
    "unrelated.service",
    "fixtureXservice",
    "fixture@.service",
]:
    assert not re.fullmatch(helper["regex"], unit), unit
for host, cfg in contract["hosts"].items():
    assert all(cfg["assertions"]), host
    notifier = cfg["notifier"]
    if host in inventory:
        assert notifier["ExecStart"].endswith("/bin/true"), (host, notifier)
        assert "EnvironmentFile" not in notifier, (host, notifier)
        collector = cfg["collector"]
        assert collector["enable"] and "systemd" in collector["enabledCollectors"]
        assert "systemd" not in collector["disabledCollectors"]
        assert "--collector.systemd.unit-include=.+" in collector["extraFlags"]
        assert "--collector.systemd.unit-exclude=^$" in collector["extraFlags"]
    else:
        assert "notify-telegram" in notifier["ExecStart"]
        assert "EnvironmentFile" in notifier

rules = []
for path in sys.argv[2:]:
    with open(path) as source:
        for group in yaml.safe_load(source)["groups"]:
            rules.extend(
                rule
                for rule in group["rules"]
                if rule.get("alert")
                in ["OptedInUnitFailed", "OpenClawGatewayDown", "SystemdUnitFailed"]
            )
opted = [rule for rule in rules if rule["alert"] == "OptedInUnitFailed"]
assert {rule["labels"]["host"] for rule in opted} == {
    host for host, units in inventory.items() if units
}
gateway = next(rule for rule in rules if rule["alert"] == "OpenClawGatewayDown")
assert gateway["labels"]["severity"] == "critical" and gateway["for"] == "5m"
assert (
    next(rule for rule in rules if rule["alert"] == "SystemdUnitFailed")["labels"][
        "severity"
    ]
    == "warning"
)


def expected(rule, labels):
    # Render only the fixture's simple label substitutions. Explore panes
    # are independently constructed and decoded in the rendering contracts.
    annotations = {
        key: re.sub(r"{{\s*\$labels\.(\w+)\s*}}", lambda match: labels[match[1]], value)
        for key, value in rule["annotations"].items()
        if key != "logs"
    }
    if "logs" in rule["annotations"]:
        panes = {
            "a": {
                "datasource": "loki",
                "queries": [
                    {
                        "refId": "A",
                        "datasource": {"type": "loki", "uid": "loki"},
                        "expr": '{host="link",unit=' + json.dumps(labels["name"]) + "}",
                    }
                ],
                "range": {"from": "now-1h", "to": "now"},
            }
        }
        annotations["logs"] = (
            rule["annotations"]["logs"].split("&panes=", 1)[0]
            + "&panes="
            + quote_plus(json.dumps(panes, separators=(",", ":")))
        )
    return {
        "exp_labels": {
            **labels,
            **{
                key: re.sub(
                    r"{{\s*\$labels\.(\w+)\s*}}", lambda match: labels[match[1]], value
                )
                for key, value in rule["labels"].items()
            },
        },
        "exp_annotations": annotations,
    }


tests = []
for rule in opted:
    host = rule["labels"]["host"]
    assert rule["for"] == "0s"
    pattern = json.loads(re.search(r'name=~("(?:[^"\\]|\\.)*")', rule["expr"])[1])
    for unit in inventory[host]:
        name = unit.replace("@.service", "@fixture.service")
        assert re.fullmatch(pattern, name), (host, unit, pattern)
        labels = {
            "job": f"{host}-node",
            "instance": host,
            "name": name,
            "state": "failed",
        }
        series = (
            "node_systemd_unit_state{"
            + ",".join(f"{key}={json.dumps(value)}" for key, value in labels.items())
            + "}"
        )
        tests.append(
            {
                "name": f"single-sample {host}/{name}",
                "interval": "30s",
                "input_series": [{"series": series, "values": "0 1 0+0x20"}],
                "alert_rule_test": [
                    {
                        "eval_time": "30s",
                        "alertname": "OptedInUnitFailed",
                        "exp_alerts": [expected(rule, labels)],
                    },
                    {
                        "eval_time": "1m",
                        "alertname": "OptedInUnitFailed",
                        "exp_alerts": [expected(rule, labels)],
                    },
                    {
                        "eval_time": "3m",
                        "alertname": "OptedInUnitFailed",
                        "exp_alerts": [],
                    },
                    {
                        "eval_time": "6m",
                        "alertname": "SystemdUnitFailed",
                        "exp_alerts": [],
                    },
                ],
            }
        )
    assert not re.fullmatch(pattern, "fixture-not-opted.service"), pattern

# Failed units on an unregistered host and non-opted units must never page.
tests.append(
    {
        "name": "non-opted host and units",
        "interval": "30s",
        "input_series": [
            {
                "series": 'node_systemd_unit_state{job="link-node",instance="link",name="fixture-not-opted.service",state="failed"}',
                "values": "1+0x20",
            },
            {
                "series": 'node_systemd_unit_state{job="zelda-node",instance="zelda",name="forgejo.service",state="failed"}',
                "values": "1+0x20",
            },
            {
                "series": 'node_systemd_unit_state{job="marin-node",instance="marin",name="forgejo.service",state="failed"}',
                "values": "1+0x20",
            },
        ],
        "alert_rule_test": [
            {"eval_time": "6m", "alertname": "OptedInUnitFailed", "exp_alerts": []}
        ],
    }
)

for name, overrides, fires in [
    ("healthy refresh", {}, False),
    ("gateway inactive", {"openclaw_gateway_active": "0+0x24"}, True),
    ("HTTP unhealthy", {"openclaw_gateway_healthy": "0+0x24"}, True),
    (
        "all gateway metrics absent",
        {
            "openclaw_gateway_active": None,
            "openclaw_gateway_healthy": None,
            "openclaw_metrics_last_update_timestamp_seconds": None,
        },
        True,
    ),
    ("missing active metric", {"openclaw_gateway_active": None}, True),
    ("missing HTTP metric", {"openclaw_gateway_healthy": None}, True),
    (
        "missing freshness metric",
        {"openclaw_metrics_last_update_timestamp_seconds": None},
        True,
    ),
    (
        "stale healthy file",
        {"openclaw_metrics_last_update_timestamp_seconds": "0+0x24"},
        True,
    ),
    (
        "exporter down",
        {
            "up": "0+0x24",
            "openclaw_gateway_active": None,
            "openclaw_gateway_healthy": None,
            "openclaw_metrics_last_update_timestamp_seconds": None,
        },
        False,
    ),
    (
        "normal startup",
        {
            "openclaw_gateway_active": "_ _ _ _ 1+0x20",
            "openclaw_gateway_healthy": "_ _ _ _ 1+0x20",
            "openclaw_metrics_last_update_timestamp_seconds": "_ _ _ _ 120+30x20",
        },
        False,
    ),
    ("gateway resolves", {"openclaw_gateway_active": "0+0x11 1+0x12"}, False),
]:
    values = {
        "up": "1+0x24",
        "openclaw_gateway_active": "1+0x24",
        "openclaw_gateway_healthy": "1+0x24",
        "openclaw_metrics_last_update_timestamp_seconds": "0+30x24",
        **overrides,
    }
    tests.append(
        {
            "name": name,
            "interval": "30s",
            "input_series": [
                {
                    "series": metric + '{job="link-node",instance="link"}',
                    "values": samples,
                }
                for metric, samples in values.items()
                if samples is not None
            ],
            "alert_rule_test": [
                {
                    "eval_time": "10m",
                    "alertname": "OpenClawGatewayDown",
                    "exp_alerts": [expected(gateway, {"instance": "link"})]
                    if fires
                    else [],
                }
            ],
        }
    )

# Prove recovery follows an actual firing state, and opted-in sustained
# failures do not also appear as generic warnings.
next(test for test in tests if test["name"] == "gateway resolves")[
    "alert_rule_test"
].insert(
    0,
    {
        "eval_time": "5m",
        "alertname": "OpenClawGatewayDown",
        "exp_alerts": [expected(gateway, {"instance": "link"})],
    },
)
for rule in opted:
    host = rule["labels"]["host"]
    name = inventory[host][0].replace("@.service", "@fixture.service")
    labels = {"job": f"{host}-node", "instance": host, "name": name, "state": "failed"}
    selector = ",".join(f"{key}={json.dumps(value)}" for key, value in labels.items())
    tests.append(
        {
            "name": f"sustained {host}/{name}",
            "interval": "30s",
            "input_series": [
                {
                    "series": "node_systemd_unit_state{" + selector + "}",
                    "values": "1+0x20",
                }
            ],
            "alert_rule_test": [
                {
                    "eval_time": "6m",
                    "alertname": "OptedInUnitFailed",
                    "exp_alerts": [expected(rule, labels)],
                },
                {"eval_time": "6m", "alertname": "SystemdUnitFailed", "exp_alerts": []},
            ],
        }
    )
warning = next(rule for rule in rules if rule["alert"] == "SystemdUnitFailed")
labels = {
    "job": "link-node",
    "instance": "link",
    "name": "fixture-not-opted.service",
    "state": "failed",
}
next(test for test in tests if test["name"] == "non-opted host and units")[
    "alert_rule_test"
].append(
    {
        "eval_time": "6m",
        "alertname": "SystemdUnitFailed",
        "exp_alerts": [
            expected(warning, labels),
            expected(
                warning,
                {
                    **labels,
                    "job": "marin-node",
                    "instance": "marin",
                    "name": "forgejo.service",
                },
            ),
        ],
    }
)

with open("unit-rules.json", "w") as output:
    json.dump(
        {"groups": [{"name": "delivery", "interval": "30s", "rules": rules}]}, output
    )
with open("unit-suite.json", "w") as output:
    json.dump(
        {
            "rule_files": ["unit-rules.json"],
            "evaluation_interval": "30s",
            "tests": tests,
        },
        output,
    )
print(f"validated host delivery ownership and prepared {len(tests)} rule scenarios")

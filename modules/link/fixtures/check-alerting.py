"""Offline contracts against the shipped Alertmanager config and Prometheus rules."""

import json
import re
import subprocess
import sys

import yaml
from alert_format_contract import check_message


def inhibition(config_path):
    with open(config_path) as source:
        config = json.load(source)

    def matches(matchers, labels):
        for matcher in matchers:
            match = re.fullmatch(r'(\w+)(=~|=|!~|!=)"(.*)"', matcher)
            assert match, f"unsupported matcher in contract: {matcher}"
            key, operator, expected = match.groups()
            actual = labels.get(key, "")
            result = (
                re.fullmatch(expected, actual) is not None
                if operator in ("=~", "!~")
                else actual == expected
            )
            if result == (operator in ("!=", "!~")):
                return False
        return True

    def inhibited(source, target):
        return any(
            matches(rule["source_matchers"], source)
            and matches(rule["target_matchers"], target)
            and all(source.get(key, "") == target.get(key, "") for key in rule["equal"])
            for rule in config["inhibit_rules"]
        )

    plex = {
        "alertname": "EndpointDown",
        "endpoint": "plex.example",
        "backend_host": "alexandria",
        "site": "nyc",
        "access_path": "published",
        "probe_exporter": "link",
    }
    backend = {**plex, "alertname": "PlexBackendDown", "access_path": "direct"}
    route = {**plex, "alertname": "PublishedRouteDown"}
    dns = {"alertname": "AllDnsProbesFailed", "site": "nyc"}
    exporter = {"alertname": "BlackboxExporterDown", "probe_exporter": "link"}
    host = {"alertname": "NixOSHostExporterDown", "backend_host": "alexandria"}
    cases = [
        (backend, plex, True),
        (route, plex, True),
        ({**backend, "endpoint": "other.example"}, plex, False),
        (backend, route, False),
        (route, backend, False),
        (dns, plex, True),
        (dns, route, True),
        (dns, backend, False),
        ({**dns, "site": "elsewhere"}, plex, False),
        (exporter, plex, True),
        (exporter, route, True),
        (exporter, backend, False),
        ({**exporter, "probe_exporter": "impa"}, plex, False),
        (host, plex, True),
        ({**host, "backend_host": "link"}, plex, False),
        ({**host, "backend_host": "impa"}, plex, False),
    ]
    for source, target, expected in cases:
        assert inhibited(source, target) == expected, (source, target, expected)
    for rule in config["inhibit_rules"]:
        # Alertmanager equates missing and empty labels. Both matcher sides
        # must explicitly reject missing dependency labels.
        for key in rule["equal"]:
            assert f'{key}=~".+"' in rule["source_matchers"]
            assert f'{key}=~".+"' in rule["target_matchers"]
        assert not inhibited(
            {"alertname": "PlexBackendDown"}, {"alertname": "EndpointDown"}
        )
    assert config["route"]["group_wait"] == "30s"
    assert config["route"]["repeat_interval"] == "4h"
    receiver = next(item for item in config["receivers"] if item["name"] == "telegram")
    telegram = receiver["telegram_configs"][0]
    assert telegram["send_resolved"] is True
    assert isinstance(telegram["chat_id"], int)
    assert telegram["parse_mode"] == ""
    print(
        f"validated {len(cases)} inhibition cases, missing-label guards, and delivery settings"
    )


def render(config_path, formatter):
    with open(config_path) as source:
        config = json.load(source)
    receiver = next(item for item in config["receivers"] if item["name"] == "telegram")
    message = receiver["telegram_configs"][0]["message"]
    with open("message.tmpl", "w") as output:
        output.write('{{ define "telegram" }}' + message + "{{ end }}")

    def render_notification(alerts, status):
        with open("notification.json", "w") as output:
            json.dump(
                {"receiver": "telegram", "status": status, "alerts": alerts}, output
            )
        return subprocess.run(
            [
                "amtool",
                "template",
                "render",
                "--template.glob=message.tmpl",
                '--template.text={{ template "telegram" . }}',
                "--template.data=notification.json",
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout

    cases = [
        (
            "2026-09-28T00:36:00Z",
            "2026-09-27 20:36 EDT",
            "2026-09-30T15:40:00Z",
            "2026-09-30 11:40 EDT",
        ),
        (
            "2026-01-01T00:36:00Z",
            "2025-12-31 19:36 EST",
            "2026-01-02T15:40:00Z",
            "2026-01-02 10:40 EST",
        ),
    ]
    for starts_at, start_time, ends_at, end_time in cases:
        for status in ["firing", "resolved"]:
            for label in ["endpoint", "service", "instance", "unit"]:
                target = (
                    "fixture.service on link" if label == "unit" else "example-target"
                )
                with open("notification.json", "w") as output:
                    json.dump(
                        {
                            "receiver": "telegram",
                            "status": status,
                            "alerts": [
                                {
                                    "status": status,
                                    "labels": {
                                        "alertname": "ExampleAlert",
                                        label: "fixture.service"
                                        if label == "unit"
                                        else "example-target",
                                        **({"host": "link"} if label == "unit" else {}),
                                    },
                                    "startsAt": starts_at,
                                    "endsAt": ends_at,
                                    "annotations": {
                                        "summary": "Example summary",
                                        "description": "Example hint",
                                        "runbook": "https://example.com/runbook",
                                        "logs": "https://example.com/logs",
                                    },
                                }
                            ],
                        },
                        output,
                    )
                rendered = subprocess.run(
                    [
                        "amtool",
                        "template",
                        "render",
                        "--template.glob=message.tmpl",
                        '--template.text={{ template "telegram" . }}',
                        "--template.data=notification.json",
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout
                for expected in [
                    "✅ RESOLVED" if status == "resolved" else "🔴 FIRING",
                    "ExampleAlert",
                    target,
                    start_time,
                ]:
                    assert expected in rendered, (expected, rendered)
                for diagnostic in [
                    "Example summary",
                    "Hint: Example hint",
                    "Runbook: https://example.com/runbook",
                    "Logs: https://example.com/logs",
                ]:
                    assert (diagnostic in rendered) == (status == "firing"), rendered
                check_message(
                    rendered,
                    "ExampleAlert",
                    target,
                    status,
                    since=start_time,
                    ended=end_time,
                )
                shell = subprocess.run(
                    [
                        "bash",
                        "-euo",
                        "pipefail",
                        "-c",
                        'source "$1"; render_alert "$2" ExampleAlert "$3" "$(date -d "$4" +%s)" "$(date -d "$5" +%s)" "Example summary" "Example hint"',
                        "offline",
                        formatter,
                        status,
                        target,
                        starts_at,
                        ends_at,
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout
                # Optional runbook output follows the same required prefix.
                assert rendered.strip().split("Runbook:")[0].strip() == shell.strip(), (
                    rendered,
                    shell,
                )

    # Group status is firing, but diagnostics must depend on each alert's status.
    alerts = [
        {
            "status": status,
            "labels": {
                "alertname": f"Mixed{status.title()}",
                "endpoint": "mixed-target",
            },
            "startsAt": cases[0][0],
            "endsAt": cases[0][2],
            "annotations": {
                "summary": f"{status} summary",
                "description": f"{status} hint",
                "runbook": f"https://example.com/{status}/runbook",
                "logs": f"https://example.com/{status}/logs",
            },
        }
        for status in ["resolved", "firing"]
    ]
    for batch in [alerts, list(reversed(alerts))]:
        rendered = render_notification(batch, "firing")
        sections = re.findall(r"[✅🔴].*?(?=[✅🔴]|\Z)", rendered, re.DOTALL)
        assert len(sections) == 2, rendered
        for alert, section in zip(batch, sections):
            status = alert["status"]
            check_message(
                section,
                alert["labels"]["alertname"],
                "mixed-target",
                status,
                since=cases[0][1],
                ended=cases[0][3],
            )
            for diagnostic in [
                f"{status} summary",
                f"Hint: {status} hint",
                f"Runbook: https://example.com/{status}/runbook",
                f"Logs: https://example.com/{status}/logs",
            ]:
                assert (diagnostic in section) == (status == "firing"), section

    # Missing annotations and target labels remain safe in both states.
    for status in ["firing", "resolved"]:
        rendered = render_notification(
            [
                {
                    "status": status,
                    "labels": {"alertname": "UnknownTarget"},
                    "startsAt": cases[0][0],
                    "endsAt": cases[0][2],
                    "annotations": {},
                }
            ],
            status,
        )
        if status == "resolved":
            check_message(
                rendered,
                "UnknownTarget",
                "unknown target",
                status,
                since=cases[0][1],
                ended=cases[0][3],
            )
        else:
            assert rendered.strip().splitlines() == [
                "🔴 FIRING: UnknownTarget",
                f"unknown target — since {cases[0][1]}",
            ], rendered
    print(
        "rendered 16 firing/resolved notifications matching the shell renderer with New York summer/winter times, plus mixed-state and missing-annotation/target cases offline"
    )


def prometheus_config(config_path):
    with open(config_path) as source:
        config = yaml.safe_load(source)
    jobs = [
        job for job in config["scrape_configs"] if job["job_name"] == "alertmanager"
    ]
    assert len(jobs) == 1
    assert jobs[0]["static_configs"] == [
        {"targets": ["127.0.0.1:9093"], "labels": {"instance": "link"}}
    ], jobs[0]
    targets = [
        target
        for manager in config["alerting"]["alertmanagers"]
        for group in manager.get("static_configs", [])
        for target in group["targets"]
    ]
    assert targets == ["127.0.0.1:9093"], targets
    print("validated normalized loopback Alertmanager scrape and discovery targets")


def rules(fixtures_path, plex_endpoint, rule_paths):
    alert_rules = {}
    groups = []
    needed_recordings = {
        "endpoint:excusal_signal",
        "endpoint:excused",
        "endpoint:alert_dependencies",
        "endpoint:probe_success_unexcused",
    }
    tested_alerts = [
        "EndpointDown",
        "PlexBackendDown",
        "PublishedRouteDown",
        "BlackboxExporterDown",
        "PrometheusScrapeTargetDown",
    ]
    with open(fixtures_path) as source:
        fixtures = json.load(source)
    for path in rule_paths:
        with open(path) as source:
            for group in yaml.safe_load(source)["groups"]:
                for rule in group["rules"]:
                    if "alert" in rule:
                        alert_rules[rule["alert"]] = rule
                # Keep the exact shipped expressions and timing, excluding
                # unrelated full-window subqueries. Those have their own SLO
                # suite; evaluating them here exceeds promtool's sample limit.
                selected = [
                    rule
                    for rule in group["rules"]
                    if rule.get("record") in needed_recordings
                    or rule.get("alert") in tested_alerts
                ]
                if selected:
                    groups.append({**group, "rules": selected})
    with open("selected-rules.json", "w") as output:
        json.dump({"groups": groups}, output)

    def annotations(rule, labels):
        return {
            key: re.sub(
                r"{{\s*\$labels\.(\w+)\s*}}", lambda match: labels[match[1]], value
            )
            for key, value in rule.get("annotations", {}).items()
        }

    assert alert_rules["PrometheusScrapeTargetDown"]["labels"]["severity"] == "warning"
    assert alert_rules["PrometheusScrapeTargetDown"]["for"] == "10m"
    for name in tested_alerts[:-1]:
        assert alert_rules[name]["labels"]["severity"] == "critical"
        assert alert_rules[name]["annotations"]["description"]
        assert alert_rules[name]["annotations"]["runbook"]
    for name in tested_alerts[:3]:
        assert alert_rules[name]["for"] == "5m"
    # Extract the exact shared published-success expression from the shipped
    # route alert to verify unknown telemetry is not displayed as success.
    published_success = alert_rules["PublishedRouteDown"]["expr"].split(
        " == 0) and on (endpoint)", 1
    )[0][1:]

    tests = []
    for fixture in fixtures:
        endpoint = fixture.get("endpoint", plex_endpoint)
        series = list(fixture.get("extra_series", []))

        def add_pair(
            job, values, labels, probe_key="probe", endpoint=endpoint, series=series
        ):
            identity = {
                "job": job,
                "endpoint": endpoint,
                "instance": endpoint,
                **labels,
            }
            selector = ",".join(
                f"{key}={json.dumps(value)}" for key, value in identity.items()
            )
            for metric, key in [("probe_success", probe_key), ("up", "up")]:
                if key in values:
                    series.append(
                        {"series": f"{metric}{{{selector}}}", "values": values[key]}
                    )

        if "direct" in fixture:
            add_pair(
                "blackbox-plex-direct", fixture["direct"], {"access_path": "direct"}
            )
        if "published" in fixture:
            values = fixture["published"]
            for resolver in ["link", "impa"]:
                add_pair(
                    "blackbox-internal",
                    values,
                    {
                        "access_path": "published",
                        "slo_class": "internal",
                        "resolver": resolver,
                    },
                    "impa_probe"
                    if resolver == "impa" and "impa_probe" in values
                    else "probe",
                )

        test = {
            "name": fixture["name"],
            "interval": "1m",
            "input_series": series,
            "alert_rule_test": [],
        }
        for check in fixture["checks"]:
            for name in tested_alerts:
                expected = []
                if name in check["firing"]:
                    labels = {"endpoint": endpoint}
                    if name == "EndpointDown":
                        labels["slo_class"] = "internal"
                        if endpoint == plex_endpoint:
                            labels.update(
                                backend_host="alexandria",
                                site="nyc",
                                probe_exporter="link",
                                access_path="published",
                            )
                    elif name == "PrometheusScrapeTargetDown":
                        labels = {"job": "alertmanager", "instance": "link"}
                    elif name == "BlackboxExporterDown":
                        labels = {"job": "blackbox", "instance": "link"}
                    # Assert the produced labels, including annotation inputs,
                    # without maintaining copies of production prose.
                    labels.update(
                        {
                            key: re.sub(
                                r"{{\s*\$labels\.(\w+)\s*}}",
                                lambda m, labels=labels: labels[m[1]],
                                value,
                            )
                            for key, value in alert_rules[name]["labels"].items()
                        }
                    )
                    expected = [
                        {
                            "exp_labels": labels,
                            "exp_annotations": annotations(alert_rules[name], labels),
                        }
                    ]
                test["alert_rule_test"].append(
                    {
                        "eval_time": check["at"],
                        "alertname": name,
                        "exp_alerts": expected,
                    }
                )
        test["promql_expr_test"] = [
            {
                "expr": item["expr"].replace("PUBLISHED_SUCCESS", published_success),
                "eval_time": item["at"],
                "exp_samples": [{"labels": "{}", "value": item["value"]}],
            }
            for item in fixture.get("expressions", [])
        ]
        tests.append(test)
    with open("suite.json", "w") as output:
        json.dump(
            {
                "rule_files": ["selected-rules.json"],
                "evaluation_interval": "1m",
                "group_eval_order": [group["name"] for group in groups],
                "tests": tests,
            },
            output,
        )
    # Prove Plex ownership does not depend on which alert group evaluates first.
    with open("suite.json") as source:
        reversed_suite = json.load(source)
    reversed_suite["group_eval_order"].reverse()
    # The generic alert consumes a separate recording group. Reversing those
    # groups makes its first pending evaluation one tick later; this is not
    # the Plex race, whose ownership uses raw telemetry in either order.
    for test in reversed_suite["tests"]:
        generic_times = {
            item["eval_time"]
            for item in test["alert_rule_test"]
            if item["alertname"] == "EndpointDown" and item["exp_alerts"]
        }
        for item in test["alert_rule_test"]:
            if item["eval_time"] in generic_times:
                assert item["eval_time"].endswith("m")
                item["eval_time"] = f"{int(item['eval_time'][:-1]) + 1}m"
    with open("suite-reversed.json", "w") as output:
        json.dump(reversed_suite, output)
    print(
        f"prepared {len(tests)} scenarios against production rule files in both group orders"
    )


if __name__ == "__main__":
    if sys.argv[1] == "inhibition":
        inhibition(sys.argv[2])
    elif sys.argv[1] == "render":
        render(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "config":
        prometheus_config(sys.argv[2])
    elif sys.argv[1] == "rules":
        rules(sys.argv[2], sys.argv[3], sys.argv[4:])
    else:
        raise SystemExit("expected inhibition, render, config or rules")

"""Check evaluated TickScope integration and exercise dashboard PromQL with promtool.

Label shapes follow TickScope v2.0.1 PrometheusWriter.java: statistic, window,
area (no pool), gc, world, event and stage; plus Prometheus target labels.
"""

import json
import re
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
dashboard = data["grafana"]
(job,) = data["tickscopeScrapes"]
assert job["job_name"] == "minecraft-paper"
assert job["scrape_interval"] == "60s"
(survival,) = [
    target
    for target in job["static_configs"]
    if target["labels"]["server_id"] == "survival"
]
assert survival["targets"] == ["127.0.0.1:9225"]
assert survival["labels"] == {
    "instance": "link",
    "server_id": "survival",
    "game": "minecraft-paper",
    "service_name": "games",
}
(discovered,) = data["discoveredTickscopeScrapes"]
assert any(
    target["labels"]["server_id"] == "creative"
    and target["targets"] == ["127.0.0.1:9226"]
    for target in discovered["static_configs"]
)
(keep,) = [rule for rule in job["metric_relabel_configs"] if rule["action"] == "keep"]
assert not re.fullmatch(keep["regex"], "mc_world_entities_by_type")
assert not re.fullmatch(keep["regex"], "mc_player_ping_seconds")

panels = dashboard["panels"]
(row_index,) = [
    i
    for i, panel in enumerate(panels)
    if panel["title"] == "Survival server performance (TickScope)"
]
assert panels[row_index]["type"] == "row"
tick_panels = panels[row_index + 1 :]
assert not any(panel["type"] == "row" for panel in tick_panels)
by_title = {panel["title"]: panel for panel in tick_panels}
assert len(by_title) == len(tick_panels)
(server,) = [
    variable
    for variable in dashboard["templating"]["list"]
    if variable["name"] == "server"
]
assert server["multi"] and server["includeAll"] and server["allValue"] == ".*"
assert "games_server_enabled" in server["query"]  # Choices survive Paper sleep.

expressions = []
for panel in tick_panels:
    for target in panel["targets"]:
        expr = target["expr"]
        assert 'server=~"$server"' in expr
        assert 'job="minecraft-paper"' in expr and 'instance="link"' in expr
        assert "and on(instance,server_id) (up{" in expr and " == 1)" in expr
        assert "or vector" not in expr
        for metric in re.findall(r"\b(mc_\w+)\{", expr):
            assert re.fullmatch(keep["regex"], metric), metric
        expressions.append(
            expr.replace("$__rate_interval", "4m").replace(
                "$server", "survival|creative"
            )
        )
    if panel["type"] == "stat":
        assert all(target["instant"] for target in panel["targets"])
        assert panel["fieldConfig"]["defaults"]["noValue"] == "Asleep / no data"
        assert panel["options"]["graphMode"] == "none"
    else:
        assert panel["fieldConfig"]["defaults"]["custom"]["spanNulls"] is False
        assert panel["interval"] == "60s"

assert 'window="1m"' in by_title["TPS (current)"]["targets"][0]["expr"]
assert 'statistic="avg"' in by_title["MSPT (current)"]["targets"][0]["expr"]
assert [
    step["value"]
    for step in by_title["TPS (current)"]["fieldConfig"]["defaults"]["thresholds"][
        "steps"
    ]
] == [None, 18, 19.5]
assert [
    step["value"]
    for step in by_title["MSPT (current)"]["fieldConfig"]["defaults"]["thresholds"][
        "steps"
    ]
] == [None, 40, 50]
assert all(
    'area="heap"' in target["expr"] for target in by_title["JVM heap"]["targets"]
)
assert all(
    "{{gc}}" in target["legendFormat"]
    for title in ("GC time rate", "GC collection rate")
    for target in by_title[title]["targets"]
)
assert (
    'event=~"login|chat|death"'
    in by_title["TickScope event rates"]["targets"][0]["expr"]
)
assert "{{version}}" in by_title["TickScope version"]["targets"][0]["legendFormat"]
assert "{{paper}}" in by_title["Paper version"]["targets"][0]["legendFormat"]


def labels(server_id="survival", **extra):
    return {
        "job": "minecraft-paper",
        "instance": "link",
        "server_id": server_id,
        "game": "minecraft-paper",
        "service_name": "games",
        **extra,
    }


def series(metric, server="survival", **extra):
    # up has static target labels only; all exporter samples also have server.
    return (
        metric
        + "{"
        + ",".join(
            f'{key}="{value}"'
            for key, value in sorted(
                labels(
                    server, **({} if metric == "up" else {"server": server}), **extra
                ).items()
            )
        )
        + "}"
    )


def query(title, index=0):
    return (
        by_title[title]["targets"][index]["expr"]
        .replace("$__rate_interval", "4m")
        .replace("$server", "survival|creative")
    )


def sample(metric, value, server="survival", arithmetic=False, **extra):
    return {
        "labels": series("" if arithmetic else metric, server, **extra),
        "value": value,
    }


inputs = [
    {"series": series("up", server), "values": "1+0x5 0+0x5"}
    for server in ("survival", "creative")
]
for server in ("survival", "creative"):
    for metric, extra, values in [
        ("mc_tps", {"window": "1m"}, "20+0x11"),
        ("mc_tps", {"window": "5m"}, "18+0x11"),
        ("mc_tick_duration_seconds", {"statistic": "avg"}, "0.045+0x11"),
        ("mc_tick_duration_seconds", {"statistic": "p95"}, "0.080+0x11"),
        ("mc_players_online", {}, "0+0x11"),
        ("mc_players_max", {}, "20+0x11"),
        ("mc_jvm_memory_used_bytes", {"area": "heap"}, "100+0x11"),
        ("mc_jvm_memory_used_bytes", {"area": "nonheap"}, "200+0x11"),
        ("mc_collection_last_success_timestamp_seconds", {"stage": "main"}, "120+0x11"),
        ("mc_collection_last_success_timestamp_seconds", {"stage": "never"}, "0+0x11"),
        (
            "mc_collection_last_success_timestamp_seconds",
            {"stage": "disabled"},
            "0+0x11",
        ),
        ("mc_collection_enabled", {"stage": "main"}, "1+0x11"),
        ("mc_collection_enabled", {"stage": "never"}, "1+0x11"),
        ("mc_collection_enabled", {"stage": "disabled"}, "0+0x11"),
    ]:
        inputs.append({"series": series(metric, server, **extra), "values": values})
    for world in ("world", "world_nether"):
        inputs.append(
            {
                "series": series("mc_world_chunks", server, world=world),
                "values": "10+0x11",
            }
        )
    for gc in ("G1 Young Generation", "G1 Old Generation"):
        # Reset within the range exercises rate's counter-reset handling.
        inputs.append(
            {
                "series": series("mc_jvm_gc_collections_total", server, gc=gc),
                "values": "0 1 2 0 1 2 3 4 5 6 7 8",
            }
        )

cases = []
for title, metric, value, extra, arithmetic in [
    ("TPS (current)", "mc_tps", 20, {"window": "1m"}, False),
    ("MSPT (current)", "mc_tick_duration_seconds", 45, {"statistic": "avg"}, True),
    ("TickScope players online", "mc_players_online", 0, {}, False),
    ("JVM heap", "mc_jvm_memory_used_bytes", 100, {"area": "heap"}, False),
    (
        "Collection last success age",
        "mc_collection_last_success_timestamp_seconds",
        120,
        {"stage": "main"},
        True,
    ),
]:
    cases.append(
        {
            "expr": query(title),
            "eval_time": "4m",
            "exp_samples": [
                sample(metric, value, server, arithmetic=arithmetic, **extra)
                for server in ("survival", "creative")
            ],
        }
    )
cases.append(
    {
        "expr": query("Loaded chunks by world"),
        "eval_time": "4m",
        "exp_samples": [
            sample("mc_world_chunks", 10, server, world=world)
            for server in ("survival", "creative")
            for world in ("world", "world_nether")
        ],
    }
)
cases.append(
    {
        "expr": query("GC collection rate"),
        "eval_time": "4m",
        "exp_samples": [
            sample(
                "mc_jvm_gc_collections_total", 1 / 90, server, arithmetic=True, gc=gc
            )
            for server in ("survival", "creative")
            for gc in ("G1 Young Generation", "G1 Old Generation")
        ],
    }
)
cases.append(
    {
        "expr": query("Collection first success"),
        "eval_time": "4m",
        "exp_samples": [
            sample(
                "mc_collection_last_success_timestamp_seconds",
                value,
                server,
                arithmetic=True,
                stage=stage,
            )
            for server in ("survival", "creative")
            for stage, value in (("main", 1), ("never", 0))
        ],
    }
)
# Keep exporter samples present: up=0 alone must suppress every panel, including
# rolling rates that would otherwise survive for several minutes after sleep.
cases.extend(
    {"expr": expr, "eval_time": "6m", "exp_samples": []} for expr in expressions
)
tests = {
    "rule_files": [],
    "fuzzy_compare": True,
    "evaluation_interval": "1m",
    "tests": [
        {
            "name": "awake, reset, multi-server and sleep",
            "interval": "1m",
            "input_series": inputs,
            "promql_expr_test": cases,
        },
        {
            "name": "absent telemetry",
            "interval": "1m",
            "input_series": [],
            "promql_expr_test": [
                {"expr": expr, "eval_time": "6m", "exp_samples": []}
                for expr in expressions
            ],
        },
    ],
}
Path(sys.argv[2]).write_text(json.dumps(tests))
print("TickScope scrape labels, dashboard structure and metric retention passed")

# Structural validation for the Nix-generated Grafana dashboards.
#
# The dashboards used to be opaque `builtins.toJSON` blobs built inside a NixOS
# module, so nothing could look at them without building a system. They are now
# exposed as `flake.grafanaDashboards`, and this check asserts the properties
# that were silently violated before: panels without units rendering raw
# numbers, `stat` panels pointed at many-series booleans rendering a wall of
# 1's, and hand-written grid coordinates overlapping.
{ lib, config, ... }:
let
  dashboards = config.flake.grafanaDashboards;
  viz = import ../../lib/grafana.nix { inherit lib; };

  # Unit ids as spelled in grafana-data's `valueFormats/categories.ts`.
  knownUnits = [
    "none"
    "short"
    "sishort"
    "locale"
    "percent"
    "percentunit"
    "bytes"
    "decbytes"
    "Bps"
    "binBps"
    "bps"
    "Kbits"
    "Mbits"
    "pps"
    "s"
    "ms"
    "ns"
    "d"
    "dtdurations"
    "dtdurationms"
    "dthms"
    "dtdhms"
    "ops"
    "reqps"
    "iops"
    "hertz"
    "celsius"
    "dateTimeAsIso"
  ];

  # Panel types that display a number and therefore must name a unit.
  numericPanelTypes = [
    "stat"
    "gauge"
    "bargauge"
    "timeseries"
    "barchart"
    "piechart"
  ];

  # A `stat` reduces every series to one big number. Above this many series it
  # stops being a summary and becomes an unreadable grid, which is exactly the
  # failure mode this work set out to remove: point those at a table, a
  # state-timeline or a bargauge instead.
  statMultiSeriesAllowance = 4;

  # Panel types fed a Prometheus classic histogram straight into a cell grid.
  # Getting that shape wrong renders without erroring, so the shape is
  # asserted here instead.
  histogramPanelTypes = [ "heatmap" ];

  # A rate/increase window narrower than 4x the scrape interval has fewer than
  # four samples, and at exactly 1x returns *zero series*: the panel reads "No
  # data" and nothing errors. Everything here is scraped at 60s, so any
  # literal window below 4m is a bug. This is the rule that would have caught
  # the entire "No data" class the DNS dashboard rebuild started from.
  minimumRateWindowSeconds = 240;
in
{
  perSystem =
    { pkgs, ... }:
    let
      # These land in the store as files rather than environment variables:
      # the serialised dashboards are well past the size a builder's
      # environment can carry.
      dashboardsFile = pkgs.writeText "grafana-dashboards.json" (builtins.toJSON dashboards);
      configFile = pkgs.writeText "grafana-dashboard-check-config.json" (
        builtins.toJSON {
          inherit knownUnits;
          inherit numericPanelTypes;
          inherit statMultiSeriesAllowance;
          inherit histogramPanelTypes;
          inherit minimumRateWindowSeconds;
          targetlessPanelTypes = viz.targetlessTypes;
        }
      );
      validator = pkgs.writeText "validate-grafana-dashboards.py" ''
        import json, re, sys

        dashboards = json.load(open(sys.argv[1]))
        config = json.load(open(sys.argv[2]))
        known_units = set(config["knownUnits"])
        numeric_types = set(config["numericPanelTypes"])
        stat_allowance = config["statMultiSeriesAllowance"]
        targetless_types = set(config["targetlessPanelTypes"])
        histogram_types = set(config["histogramPanelTypes"])
        min_rate_window = config["minimumRateWindowSeconds"]

        # PromQL duration suffixes, in seconds.
        RANGE_UNITS = {
            "ms": 0.001,
            "s": 1,
            "m": 60,
            "h": 3600,
            "d": 86400,
            "w": 604800,
            "y": 31536000,
        }
        problems = []


        def fail(dashboard, message):
            problems.append(f"{dashboard}: {message}")


        for name, dashboard in sorted(dashboards.items()):
            # 42 is the final v1 dashboard schema. Emitting anything lower
            # makes Grafana rewrite datasource refs and panel fields on load.
            if dashboard.get("schemaVersion") != 42:
                fail(name, "schemaVersion must be 42")
            if not dashboard.get("uid"):
                fail(name, "missing uid")

            seen_ids = set()
            occupied = {}

            for panel in dashboard.get("panels", []):
                title = panel.get("title", "<untitled>")
                ptype = panel.get("type")

                panel_id = panel.get("id")
                if panel_id in seen_ids:
                    fail(name, f"{title}: duplicate panel id {panel_id}")
                seen_ids.add(panel_id)

                grid = panel.get("gridPos")
                if not grid:
                    fail(name, f"{title}: missing gridPos")
                    continue
                if grid["x"] + grid["w"] > 24:
                    fail(name, f"{title}: overflows the 24-column grid")
                # Report one line per panel, not one per overlapping cell.
                collision = None
                for y in range(grid["y"], grid["y"] + grid["h"]):
                    row = occupied.setdefault(y, set())
                    for x in range(grid["x"], grid["x"] + grid["w"]):
                        if x in row and collision is None:
                            collision = (x, y)
                        row.add(x)
                if collision is not None:
                    fail(name, f"{title}: overlaps another panel at {collision}")

                if ptype == "row":
                    # An expanded row keeps its children as siblings; filling
                    # both places duplicates or hides panels.
                    if panel.get("collapsed") is not False or panel.get("panels") != []:
                        fail(name, f"{title}: expanded rows need collapsed=false and panels=[]")
                    continue

                defaults = panel.get("fieldConfig", {}).get("defaults", {})
                unit = defaults.get("unit")
                if ptype in targetless_types:
                    continue
                if ptype in numeric_types and unit is None:
                    fail(name, f"{title}: {ptype} panel declares no unit")
                if unit is not None and unit not in known_units:
                    fail(name, f"{title}: unknown unit {unit!r}")

                thresholds = defaults.get("thresholds")
                if thresholds:
                    steps = thresholds.get("steps", [])
                    if not steps:
                        fail(name, f"{title}: thresholds with no steps")
                    elif steps[0].get("value") is not None:
                        fail(name, f"{title}: base threshold step must have value null")

                targets = panel.get("targets", [])
                if not targets and ptype not in targetless_types:
                    fail(name, f"{title}: no targets")

                # The alertlist panel filters rules by datasource *display
                # name*, not uid, so a uid here silently renders nothing.
                if ptype == "alertlist":
                    ds = panel.get("options", {}).get("datasource")
                    if ds is not None and ds.islower() and " " not in ds:
                        fail(
                            name,
                            f"{title}: alertlist options.datasource must be the datasource "
                            f"display name, not the uid {ds!r}",
                        )
                for target in targets:
                    if not target.get("expr", "").strip():
                        fail(name, f"{title}: target with empty expr")
                    # Leaving these implicit makes behaviour depend on which
                    # Grafana version renders the dashboard.
                    if "instant" not in target or "range" not in target:
                        fail(name, f"{title}: target must set instant and range")
                    if target.get("instant") and target.get("range"):
                        fail(name, f"{title}: target cannot be both instant and range")

                    # The bug this rule exists for: `rate(x[1m])` over
                    # 60s-scraped data has one sample per window and returns
                    # ZERO series. The panel says "No data" and nothing
                    # errors. Only `$__rate_interval` (>= 4m once the
                    # datasource declares timeInterval), `$__range`, `$__auto`
                    # or an explicit window of at least 4m is safe.
                    expr = target.get("expr", "")
                    if re.search(r"\b(rate|irate|increase|delta|idelta)\s*\(", expr):
                        # Strip string literals first. A label matcher like
                        # `device=~"[a-z]+[0-9]+"` contains brackets that are
                        # character classes, not range windows; a range
                        # window never appears inside a quoted string.
                        bare = re.sub(r"\"[^\"]*\"|'[^']*'", '""', expr)
                        for window in re.findall(r"\[([^\]]*)\]", bare):
                            # Subquery `[10m:1m]`: the range is the first half.
                            window = window.split(":")[0].strip()
                            if not window or window.startswith("$"):
                                continue
                            match = re.fullmatch(r"(\d+)(ms|s|m|h|d|w|y)", window)
                            if not match:
                                fail(name, f"{title}: unparseable range window [{window}]")
                                continue
                            seconds = int(match.group(1)) * RANGE_UNITS[match.group(2)]
                            if seconds < min_rate_window:
                                fail(
                                    name,
                                    f"{title}: rate window [{window}] is below "
                                    f"{min_rate_window}s; at a 60s scrape this "
                                    "returns no series at all",
                                )

                if ptype == "stat":
                    reduce = panel.get("options", {}).get("reduceOptions")
                    if not reduce or not reduce.get("calcs"):
                        fail(name, f"{title}: stat panel needs reduceOptions.calcs")
                    # Several targets in one stat means several big numbers;
                    # without value_and_name none of them is labelled.
                    if len(targets) > stat_allowance and panel.get("options", {}).get(
                        "textMode"
                    ) not in ("value_and_name", "name"):
                        fail(
                            name,
                            f"{title}: stat with {len(targets)} targets must use "
                            "textMode value_and_name so the tiles are labelled",
                        )

                # A heatmap fed a classic histogram fails silently in four
                # distinct ways. Assert the three that are visible in the JSON.
                if ptype in histogram_types:
                    options = panel.get("options", {})
                    if options.get("calculate") is not False:
                        fail(
                            name,
                            f"{title}: heatmap must set options.calculate=false "
                            "or it re-bins already-bucketed data",
                        )
                    if not options.get("yAxis", {}).get("unit"):
                        fail(
                            name,
                            f"{title}: heatmap needs options.yAxis.unit; the y "
                            "field's own unit is forced to 'short'",
                        )
                    for target in targets:
                        if target.get("format") != "heatmap":
                            fail(
                                name,
                                f"{title}: heatmap target must set format='heatmap' "
                                "or the datasource never de-accumulates the buckets",
                            )
                        legend = target.get("legendFormat")
                        if legend not in (None, "{{le}}"):
                            fail(
                                name,
                                f"{title}: heatmap legendFormat must be "
                                f"'{{{{le}}}}', not {legend!r}",
                            )
                        # More than one non-`le` dimension emits several
                        # heatmap-rows frames and the panel keeps only the
                        # last, dropping the rest with no warning.
                        for by in re.findall(r"\bby\s*\(([^)]*)\)", target.get("expr", "")):
                            labels = [lab.strip() for lab in by.split(",") if lab.strip()]
                            if "le" in labels and labels != ["le"]:
                                fail(
                                    name,
                                    f"{title}: heatmap target aggregates by "
                                    f"({by.strip()}); only `by (le)` renders -- "
                                    "extra dimensions silently drop frames",
                                )

                if ptype in ("state-timeline", "status-history"):
                    if not defaults.get("mappings") and not thresholds:
                        fail(name, f"{title}: {ptype} needs mappings or thresholds to colour states")

        if problems:
            print("Grafana dashboard validation failed:", file=sys.stderr)
            for problem in problems:
                print(f"  - {problem}", file=sys.stderr)
            sys.exit(1)

        total = sum(len(d.get("panels", [])) for d in dashboards.values())
        print(f"validated {len(dashboards)} dashboards, {total} panels")
      '';
    in
    {
      checks.grafana-dashboards =
        pkgs.runCommand "grafana-dashboards-check" { nativeBuildInputs = [ pkgs.python3 ]; }
          ''
            python3 ${validator} ${dashboardsFile} ${configFile}
            touch "$out"
          '';
    };
}

# Pure builders for the Nix-generated Grafana dashboards on the observability
# hub. Both `modules/link/observability.nix` and
# `modules/link/media-observability.nix` used to carry their own private
# `panel`/`dashboard` helpers with different signatures; neither could express
# units, thresholds, value mappings, legend options or more than one target, so
# every `stat` panel fell back to Grafana's bare defaults and rendered a wall of
# unlabelled numbers. This is the single shared implementation.
#
# Targets Grafana 11/12, dashboard schemaVersion 41. Unit ids are the literal
# strings from grafana-data's `valueFormats/categories.ts`; see `units` below.
{ lib }:
let
  # The Grafana this repository provisions. Stamped into every panel as
  # `pluginVersion` so per-panel migration handlers do not mistake generated
  # panels for output from an older Grafana.
  grafanaVersion = "13.1.3";

  inherit (lib)
    foldl'
    imap0
    imap1
    optionalAttrs
    ;

  # Grafana refuses to scale a value it has no unit for, so every numeric panel
  # must name one. These are the ids we actually use, kept as an attrset so a
  # typo is an evaluation error rather than a silently unformatted axis.
  units = {
    none = "none";
    short = "short";
    percent = "percent"; # 0-100
    percentunit = "percentunit"; # 0.0-1.0
    bytes = "bytes"; # IEC, base 1024
    decbytes = "decbytes"; # SI, base 1000
    bytesPerSecond = "Bps";
    binBytesPerSecond = "binBps";
    bitsPerSecond = "bps";
    kilobitsPerSecond = "Kbits";
    seconds = "s";
    milliseconds = "ms";
    duration = "dtdurations"; # humanised, e.g. "1 month 15 days"
    ops = "ops";
    reqps = "reqps";
    iops = "iops";
    celsius = "celsius";
    dateTimeAsIso = "dateTimeAsIso";
  };

  # Grafana's threshold steps are ordered and the base step carries a literal
  # null value. `steps [ { color = "green"; } { color = "red"; value = 1; } ]`.
  thresholdSteps =
    steps:
    map (step: {
      inherit (step) color;
      value = step.value or null;
    }) steps;

  # 0/1 booleans are the single worst offender in the existing dashboards: with
  # no mapping a `stat` shows "1", which tells the reader nothing.
  boolMapping =
    {
      falseText ? "DOWN",
      trueText ? "UP",
      falseColor ? "red",
      trueColor ? "green",
      nullText ? "NO DATA",
      nullColor ? "text",
    }:
    [
      {
        type = "value";
        options = {
          "0" = {
            text = falseText;
            color = falseColor;
            index = 1;
          };
          "1" = {
            text = trueText;
            color = trueColor;
            index = 0;
          };
        };
      }
      {
        type = "special";
        options = {
          match = "null+nan";
          result = {
            text = nullText;
            color = nullColor;
            index = 2;
          };
        };
      }
    ];

  # Shared timeseries look: a filled line with the axis floored at zero via
  # axisSoftMin (which, unlike a hard min, still lets a spike expand the axis).
  timeseriesCustom = {
    drawStyle = "line";
    lineInterpolation = "linear";
    lineWidth = 1;
    fillOpacity = 10;
    gradientMode = "opacity";
    showPoints = "never";
    pointSize = 5;
    spanNulls = false;
    insertNulls = false;
    barAlignment = 0;
    axisPlacement = "auto";
    axisLabel = "";
    axisColorMode = "text";
    axisBorderShow = false;
    axisCenteredZero = false;
    axisSoftMin = 0;
    scaleDistribution.type = "linear";
    stacking = {
      mode = "none";
      group = "A";
    };
    hideFrom = {
      legend = false;
      tooltip = false;
      viz = false;
    };
    thresholdsStyle.mode = "off";
  };

  # Log-volume bars: the bucket is the bar, so no line and full fill.
  barsCustom = timeseriesCustom // {
    drawStyle = "bars";
    lineWidth = 0;
    fillOpacity = 100;
    gradientMode = "none";
    barWidthFactor = 1;
    stacking = {
      mode = "normal";
      group = "A";
    };
  };

  reduceLast = {
    calcs = [ "lastNotNull" ];
    fields = "";
    values = false;
  };

  # Per-type `options` defaults. The old helpers hardcoded `options = {}`, which
  # is why every stat panel used Grafana's implicit fallbacks.
  optionDefaults = {
    stat = {
      reduceOptions = reduceLast;
      orientation = "auto";
      textMode = "auto";
      colorMode = "value";
      graphMode = "area";
      justifyMode = "auto";
      wideLayout = true;
      showPercentChange = false;
      percentChangeColorMode = "standard";
    };
    gauge = {
      reduceOptions = reduceLast;
      orientation = "auto";
      showThresholdLabels = false;
      showThresholdMarkers = true;
      minVizHeight = 75;
      minVizWidth = 75;
      sizing = "auto";
    };
    bargauge = {
      reduceOptions = reduceLast;
      displayMode = "gradient";
      orientation = "horizontal";
      valueMode = "color";
      showUnfilled = true;
      minVizHeight = 16;
      minVizWidth = 8;
      maxVizHeight = 300;
      sizing = "auto";
      namePlacement = "auto";
      legend = {
        calcs = [ ];
        displayMode = "list";
        placement = "bottom";
        showLegend = false;
      };
    };
    timeseries = {
      legend = {
        calcs = [
          "mean"
          "max"
          "lastNotNull"
        ];
        displayMode = "table";
        placement = "bottom";
        showLegend = true;
      };
      tooltip = {
        mode = "multi";
        sort = "desc";
        hideZeros = false;
      };
    };
    "state-timeline" = {
      mergeValues = true;
      showValue = "never";
      alignValue = "center";
      rowHeight = 0.9;
      perPage = 20;
      legend = {
        displayMode = "list";
        placement = "bottom";
        showLegend = true;
      };
      tooltip = {
        mode = "single";
        sort = "none";
      };
    };
    "status-history" = {
      showValue = "auto";
      colWidth = 0.9;
      rowHeight = 0.9;
      legend = {
        displayMode = "list";
        placement = "bottom";
        showLegend = true;
      };
      tooltip = {
        mode = "single";
        sort = "none";
      };
    };
    piechart = {
      reduceOptions = reduceLast;
      pieType = "donut";
      displayLabels = [ "percent" ];
      legend = {
        displayMode = "table";
        placement = "right";
        showLegend = true;
        values = [
          "value"
          "percent"
        ];
      };
      tooltip = {
        mode = "single";
        sort = "none";
      };
    };
    table = {
      cellHeight = "sm";
      showHeader = true;
      # Grafana 13 dropped `options.footer`; it moved to a per-field
      # `custom.footer.reducers`, so there is nothing to emit at panel level.
      enablePagination = false;
    };
    logs = {
      showTime = true;
      showLabels = false;
      showCommonLabels = false;
      wrapLogMessage = true;
      prettifyLogMessage = false;
      enableLogDetails = true;
      dedupStrategy = "none";
      sortOrder = "Descending";
      showControls = true;
      enableInfiniteScrolling = true;
      syntaxHighlighting = true;
      fontSize = "small";
    };
    # Reads Grafana's rules API, which proxies through to Prometheus's own
    # `/api/v1/rules`, so Prometheus-native alerting rules show up here even
    # though this deployment provisions no Grafana-managed rules.
    alertlist = {
      viewMode = "list";
      groupMode = "default";
      groupBy = [ ];
      maxItems = 50;
      sortOrder = 3; # importance
      dashboardAlerts = false;
      alertName = "";
      alertInstanceLabelFilter = "";
      folder = null;
      showInactiveAlerts = false;
      stateFilter = {
        firing = true;
        pending = true;
        recovering = false;
        noData = false;
        normal = false;
        error = false;
      };
    };
    dashlist = {
      keepTime = true;
      includeVars = false;
      showStarred = false;
      showRecentlyViewed = false;
      showSearch = true;
      showHeadings = false;
      showFolderNames = false;
      maxItems = 30;
      query = "";
      tags = [ ];
    };
    canvas = {
      inlineEditing = false;
      showAdvancedTypes = true;
      panZoom = false;
      zoomToContent = false;
      tooltip = {
        mode = "single";
        disableForOneClick = false;
      };
    };
    xychart = {
      mapping = "manual";
      series = [ ];
      legend = {
        showLegend = true;
        displayMode = "list";
        placement = "bottom";
        calcs = [ ];
        overflow = "ellipsis";
      };
      tooltip = {
        mode = "single";
        sort = "none";
        hideZeros = false;
        maxHeight = 600;
      };
    };
    histogram = {
      bucketCount = 30;
      bucketOffset = 0;
      combine = false;
      legend = {
        showLegend = true;
        displayMode = "list";
        placement = "bottom";
        calcs = [ ];
      };
      tooltip = {
        mode = "single";
        sort = "none";
        hideZeros = false;
      };
    };
    heatmap = {
      calculate = false;
      cellGap = 1;
      color = {
        mode = "scheme";
        scheme = "Spectral";
        steps = 64;
        reverse = true;
        exponent = 0.5;
        fill = "dark-orange";
      };
      filterValues.le = 1.0e-9;
      rowsFrame.layout = "auto";
      showValue = "never";
      legend.show = true;
      tooltip = {
        mode = "single";
        showColorScale = false;
        yHistogram = true;
      };
    };
  };

  customDefaults = {
    timeseries = timeseriesCustom;
    barchart = timeseriesCustom;
    "state-timeline" = {
      lineWidth = 0;
      fillOpacity = 80;
      spanNulls = false;
      insertNulls = false;
      hideFrom = {
        legend = false;
        tooltip = false;
        viz = false;
      };
    };
    "status-history" = {
      lineWidth = 1;
      fillOpacity = 80;
      hideFrom = {
        legend = false;
        tooltip = false;
        viz = false;
      };
    };
    xychart = {
      show = "points";
      pointShape = "circle";
      pointSize = {
        fixed = 5;
        min = 5;
        max = 100;
      };
      pointStrokeWidth = 1;
      fillOpacity = 50;
      lineWidth = 2;
      axisPlacement = "auto";
      axisLabel = "";
      axisColorMode = "text";
      axisBorderShow = false;
      axisCenteredZero = false;
      scaleDistribution.type = "linear";
      hideFrom = {
        legend = false;
        tooltip = false;
        viz = false;
      };
    };
    histogram = {
      lineWidth = 1;
      fillOpacity = 80;
      gradientMode = "none";
      stacking = {
        mode = "none";
        group = "A";
      };
      axisPlacement = "auto";
      axisLabel = "";
      axisColorMode = "text";
      axisBorderShow = false;
      axisCenteredZero = false;
      scaleDistribution.type = "linear";
      hideFrom = {
        legend = false;
        tooltip = false;
        viz = false;
      };
    };
  };

  # Panels that render without querying a datasource at all.
  targetlessTypes = [
    "alertlist"
    "dashlist"
    "annolist"
    "text"
    "row"
  ];

  refIds = [
    "A"
    "B"
    "C"
    "D"
    "E"
    "F"
    "G"
    "H"
    "I"
    "J"
    "K"
    "L"
  ];

  # Accepts either a bare PromQL/LogQL string or a list of target attrsets, and
  # assigns refIds positionally so multi-target panels stay declarative.
  mkTargets =
    { datasource, targets }:
    imap0 (
      index: target:
      {
        refId = builtins.elemAt refIds index;
        datasource.uid = target.datasource or datasource;
        inherit (target) expr;
      }
      // {
        # Both flags are set explicitly: Grafana's implicit defaulting for a
        # missing `range`/`instant` pair has changed between versions.
        instant = target.instant or false;
        range = !(target.instant or false);
        # Stops Grafana trying to reverse-parse generated PromQL into its
        # visual query builder.
        editorMode = "code";
      }
      // optionalAttrs (target ? legend) { legendFormat = target.legend; }
      // optionalAttrs (target ? format) { inherit (target) format; }
      // optionalAttrs (target ? interval) { inherit (target) interval; }
    ) targets;
in
rec {
  inherit
    units
    boolMapping
    thresholdSteps
    timeseriesCustom
    barsCustom
    grafanaVersion
    targetlessTypes
    ;

  # Grafana's own level colours, from public/app/features/logs/logsModel.ts.
  logLevelOverrides = [
    {
      matcher = {
        id = "byRegexp";
        options = "/(?i)(critical|crit|fatal|emerg|alert)/";
      };
      properties = [
        {
          id = "color";
          value = {
            mode = "fixed";
            fixedColor = "#705DA0";
          };
        }
      ];
    }
    {
      matcher = {
        id = "byRegexp";
        options = "/(?i)(error|err|eror)/";
      };
      properties = [
        {
          id = "color";
          value = {
            mode = "fixed";
            fixedColor = "#E24D42";
          };
        }
      ];
    }
    {
      matcher = {
        id = "byRegexp";
        options = "/(?i)(warn|warning)/";
      };
      properties = [
        {
          id = "color";
          value = {
            mode = "fixed";
            fixedColor = "#EAB839";
          };
        }
      ];
    }
    {
      matcher = {
        id = "byRegexp";
        options = "/(?i)(info|notice)/";
      };
      properties = [
        {
          id = "color";
          value = {
            mode = "fixed";
            fixedColor = "#1F78C1";
          };
        }
      ];
    }
    {
      matcher = {
        id = "byRegexp";
        options = "/(?i)debug/";
      };
      properties = [
        {
          id = "color";
          value = {
            mode = "fixed";
            fixedColor = "#9e9e9e";
          };
        }
      ];
    }
    {
      matcher = {
        id = "byRegexp";
        options = "/(?i)trace/";
      };
      properties = [
        {
          id = "color";
          value = {
            mode = "fixed";
            fixedColor = "#6ED0E0";
          };
        }
      ];
    }
  ];

  # Grafana 13 rebuilt the gauge panel with segmented bars, glow effects and an
  # inline sparkline. These are transcribed from the presets the 13.1.3 bundle
  # ships in `gauge/presets.ts`.
  #
  # `shape` must always be present. `gauge/migrations.ts` treats a gauge with no
  # `options.shape` and a `pluginVersion` below 13 as legacy and force-disables
  # `sparkline` and `effects`, so omitting it throws the new visuals away
  # silently. `panel` stamps `pluginVersion` for the same reason.
  gaugePresets =
    let
      base = {
        shape = "gauge";
        barShape = "flat";
        barWidthFactor = 0.54;
        endpointMarker = "point";
        segmentCount = 1;
        segmentSpacing = 0.3;
        minVizWidth = 75;
        minVizHeight = 75;
        sizing = "auto";
        textMode = "auto";
        sparkline = true;
        showThresholdMarkers = true;
        showThresholdLabels = false;
        effects = {
          barGlow = false;
          centerGlow = false;
          gradient = false;
        };
      };
    in
    rec {
      standard = base;
      # 63 segments reads as an LED bar rather than a solid arc.
      segmented = base // {
        segmentCount = 63;
      };
      gradient = base // {
        effects = base.effects // {
          gradient = true;
        };
      };
      circle = base // {
        shape = "circle";
      };
      # Rounded bar, glowing endpoint, every effect on.
      neon = base // {
        shape = "circle";
        barShape = "rounded";
        barWidthFactor = 0.25;
        endpointMarker = "glow";
        showThresholdMarkers = false;
        effects = {
          barGlow = true;
          centerGlow = true;
          gradient = true;
        };
      };
      neonSegmented = neon // {
        segmentCount = 10;
        segmentSpacing = 0.15;
      };
    };

  # Table cell renderers, as override properties.
  #
  # `pill` draws the value on a coloured lozenge. It only renders for *string*
  # fields -- a numeric field falls back to the plain renderer -- and it takes
  # its colours from the field's value mappings when there are any, otherwise
  # from a hash of the string.
  pillCell = {
    id = "custom.cellOptions";
    value.type = "pill";
  };

  colorBackgroundCell =
    {
      mode ? "basic",
      applyToRow ? false,
    }:
    {
      id = "custom.cellOptions";
      value = {
        type = "color-background";
        inherit mode applyToRow;
      };
    };

  gaugeCell =
    {
      mode ? "gradient",
    }:
    {
      id = "custom.cellOptions";
      value = {
        type = "gauge";
        inherit mode;
      };
    };

  # Renders a whole series inside one table cell. Requires the column to be a
  # `FieldType.frame`, which is what the `timeSeriesTable` transformation
  # produces from a range query.
  sparklineCell = {
    id = "custom.cellOptions";
    value = {
      type = "sparkline";
      hideValue = false;
      drawStyle = "line";
      lineInterpolation = "smooth";
      lineWidth = 1;
      fillOpacity = 40;
      gradientMode = "hue";
      showPoints = "never";
      pointSize = 2;
      barAlignment = 0;
      spanNulls = true;
    };
  };

  # `${__value.raw}`, `${__field.labels.X}` and `${__data.fields["Name"]}`
  # interpolate from the clicked datum; `${__url_time_range}` carries the
  # dashboard's current window into the target dashboard.
  dataLink =
    {
      title,
      url,
      targetBlank ? false,
    }:
    {
      inherit title url targetBlank;
    };

  # Every generated dashboard carries the `provisioned` tag, so one tag-linked
  # dropdown gives all of them a shared nav bar.
  defaultNavLinks = [
    (dashboardTagLink {
      title = "Observability";
      tags = [ "provisioned" ];
    })
  ];

  # Overlays the periods each alert was firing onto every time-based panel on
  # the dashboard. Prometheus annotations must carry their query under
  # `target`; a top-level `expr`/`step` is the legacy shape, which the
  # datasource rewrites into `target` and deletes on every load.
  #
  # Only samples with a value above zero become events, and `ALERTS` is always
  # 1 while firing, so the regions line up exactly with the firing windows.
  alertAnnotations =
    { severity, color }:
    {
      name = "${lib.toSentenceCase severity} alerts";
      enable = true;
      # Hides the toggle chip in the header, not the annotation itself.
      hide = true;
      iconColor = color;
      datasource.uid = "prometheus";
      target = {
        refId = "Anno";
        expr = ''ALERTS{alertstate="firing",severity="${severity}"}'';
        # Consecutive samples inside one step merge into a single region.
        interval = "60s";
      };
      titleFormat = "{{alertname}}";
      textFormat = "{{endpoint}}{{instance}}{{name}}";
      # A comma-separated string, not a list.
      tagKeys = "severity,alertname";
    };

  defaultAnnotations = {
    list = [
      {
        builtIn = 1;
        name = "Annotations & Alerts";
        datasource = {
          type = "grafana";
          uid = "-- Grafana --";
        };
        enable = true;
        hide = true;
        iconColor = "rgba(0, 211, 255, 1)";
        type = "dashboard";
      }
      (alertAnnotations {
        severity = "critical";
        color = "red";
      })
      (alertAnnotations {
        severity = "warning";
        color = "orange";
      })
    ];
  };

  # Nav entries rendered above the panels. `dashboards` collects every
  # dashboard carrying the given tags; `link` is an arbitrary URL.
  dashboardTagLink =
    {
      title,
      tags,
      icon ? "dashboard",
      asDropdown ? true,
      keepTime ? true,
      includeVars ? false,
    }:
    {
      type = "dashboards";
      inherit
        title
        tags
        icon
        asDropdown
        keepTime
        includeVars
        ;
      tooltip = "";
      url = "";
      targetBlank = false;
    };

  # Override one named series, e.g. to pin a colour or give a single field its
  # own unit on an otherwise-uniform panel.
  overrideByName = name: properties: {
    matcher = {
      id = "byName";
      options = name;
    };
    inherit properties;
  };

  overrideByRegexp = regexp: properties: {
    matcher = {
      id = "byRegexp";
      options = regexp;
    };
    inherit properties;
  };

  # Mirror a series below the axis (read-vs-write, rx-vs-tx).
  negativeY =
    regexp:
    overrideByRegexp regexp [
      {
        id = "custom.transform";
        value = "negative-Y";
      }
    ];

  panel =
    {
      title,
      type ? "timeseries",
      expr ? null,
      targets ? null,
      legend ? null,
      datasource ? "prometheus",
      unit ? null,
      min ? null,
      max ? null,
      decimals ? null,
      noValue ? null,
      displayName ? null,
      color ? null,
      thresholds ? null,
      mappings ? [ ],
      overrides ? [ ],
      custom ? { },
      options ? { },
      transformations ? null,
      links ? [ ],
      description ? null,
      interval ? null,
      maxDataPoints ? null,
      w ? 12,
      h ? 8,
    }:
    let
      resolvedTargets =
        if targets != null then
          targets
        else if expr != null then
          [ ({ inherit expr; } // optionalAttrs (legend != null) { inherit legend; }) ]
        else if builtins.elem type targetlessTypes then
          [ ]
        else
          throw "grafana.panel ${title}: needs either `expr` or `targets`";

      baseCustom = customDefaults.${type} or { };
      baseOptions = optionDefaults.${type} or { };
      mergedCustom = baseCustom // custom;
    in
    {
      inherit title type;
      datasource.uid = datasource;
      # Placeholder; `layout` rewrites this into a real gridPos.
      inherit w h;
      targets = mkTargets {
        inherit datasource;
        targets = resolvedTargets;
      };
      fieldConfig = {
        defaults = {
          # Value mappings carry their own colours, so a panel that has them
          # must not also be driven by the classic series palette.
          color =
            if color != null then
              color
            else if thresholds != null || mappings != [ ] then
              { mode = "thresholds"; }
            else
              { mode = "palette-classic"; };
        }
        # A mapped boolean renders text, never a number, so it has no unit to
        # name. Defaulting it keeps "every panel declares a unit" a rule the
        # dashboard check can enforce without exceptions.
        // optionalAttrs (unit != null || mappings != [ ]) {
          unit = if unit != null then unit else "none";
        }
        // optionalAttrs (min != null) { inherit min; }
        // optionalAttrs (max != null) { inherit max; }
        // optionalAttrs (decimals != null) { inherit decimals; }
        // optionalAttrs (noValue != null) { inherit noValue; }
        // optionalAttrs (displayName != null) { inherit displayName; }
        // optionalAttrs (mappings != [ ]) { inherit mappings; }
        // optionalAttrs (links != [ ]) { inherit links; }
        // optionalAttrs (thresholds != null || mappings != [ ]) {
          thresholds = {
            mode = "absolute";
            steps = thresholdSteps (if thresholds != null then thresholds else [ { color = "text"; } ]);
          };
        }
        // optionalAttrs (mergedCustom != { }) { custom = mergedCustom; };
        inherit overrides;
      };
      options = baseOptions // options;
      pluginVersion = grafanaVersion;
    }
    // optionalAttrs (transformations != null) { inherit transformations; }
    // optionalAttrs (description != null) { inherit description; }
    // optionalAttrs (interval != null) { inherit interval; }
    // optionalAttrs (maxDataPoints != null) { inherit maxDataPoints; };

  # A section header. Grafana renders an uncollapsed row as a full-width band
  # and everything laid out after it belongs to that section.
  row = title: {
    inherit title;
    type = "row";
    collapsed = false;
    panels = [ ];
    w = 24;
    h = 1;
  };

  # Turn a list of panel-rows into gridPos-carrying panels with unique ids.
  # Hand-written x/y coordinates were how the old dashboards ended up with
  # every media panel stacked full-width at h=7; here the geometry is derived.
  layout =
    rows:
    let
      placeRow =
        y: rowPanels:
        (foldl'
          (acc: p: {
            x = acc.x + p.w;
            placed = acc.placed ++ [
              (
                removeAttrs p [
                  "w"
                  "h"
                ]
                // {
                  gridPos = {
                    inherit (p) w h;
                    inherit (acc) x;
                    inherit y;
                  };
                }
              )
            ];
          })
          {
            x = 0;
            placed = [ ];
          }
          rowPanels
        ).placed;

      stepped =
        foldl'
          (
            acc: rowPanels:
            let
              tallest = foldl' (m: p: if p.h > m then p.h else m) 0 rowPanels;
            in
            {
              y = acc.y + tallest;
              panels = acc.panels ++ placeRow acc.y rowPanels;
            }
          )
          {
            y = 0;
            panels = [ ];
          }
          rows;
    in
    imap1 (id: p: p // { inherit id; }) stepped.panels;

  dashboard =
    {
      uid,
      title,
      rows,
      tags,
      description ? null,
      templating ? {
        list = [ ];
      },
      refresh ? "30s",
      from ? "now-6h",
      links ? defaultNavLinks,
      annotations ? defaultAnnotations,
      preload ? false,
    }:
    {
      inherit
        uid
        title
        templating
        tags
        refresh
        links
        preload
        ;
      panels = layout rows;
      # 42 is the final v1 dashboard schema version; Grafana explicitly will
      # not add a 43. Emitting anything lower makes Grafana run migrations that
      # rewrite datasource references and panel fields on load.
      schemaVersion = 42;
      version = 1;
      editable = false;
      graphTooltip = 1; # shared crosshair across panels
      timezone = "browser";
      time = {
        inherit from;
        to = "now";
      };
    }
    // optionalAttrs (annotations != null) { inherit annotations; }
    // optionalAttrs (description != null) { inherit description; };

  # Every panel's PromQL/LogQL, used by the privacy assertions. The previous
  # implementation only looked at each panel's *first* target, so a
  # high-cardinality selector in a second target would have gone unchecked.
  allExpressions =
    dashboards:
    lib.concatMap (value: lib.concatMap (p: map (t: t.expr) (p.targets or [ ])) (value.panels or [ ])) (
      builtins.attrValues dashboards
    );
}

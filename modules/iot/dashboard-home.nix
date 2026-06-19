# nixos-home — a declarative, Nix-generated home dashboard.
#
# This is the single-source-of-truth counterpart to the storage-mode iPad kiosk
# (`main-home`, UI-managed, NOT in this repo). It reproduces the kiosk's first
# ("Fridge") view — people locations, per-person calendars, the subway board,
# weather, cleaning status and light scenes — as a YAML-mode dashboard generated
# from Nix, so it regenerates on every rebuild with no manual ha-mcp push.
#
# It also owns the FULL set of custom Lovelace modules for this host (the single
# `customLovelaceModules` list): emitting any `lovelace.resources` flips HA to
# yaml resource_mode, which orphans HACS's storage resource collection, so every
# `custom:` card a dashboard uses must be declared here or it renders as "Custom
# element doesn't exist". See DASHBOARD.md. roomieorder.nix consumes `mushroom`
# from this list (it no longer declares its own).
#
# This dashboard REPLACES the storage kiosk: the iPad (vnc-ipad.nix) points at
# /nixos-home/home?kiosk. It carries the full kiosk: the home view plus the
# cleaning, lights and week sub-views (all declarative here). The Reorder chip
# crosses to the separate `nixos-reorder` dashboard (same catalog.json generator,
# so not a second source of truth); that dashboard has a Back chip home.
# `?kiosk` chrome (hidden header/sidebar) is the kiosk-mode plugin, declared below.
# The storage `main-home` dashboard is left intact as a fallback.
_: {
  configurations.nixos.iot.module =
    { pkgs, ... }:
    let
      yamlFormat = pkgs.formats.yaml { };

      # Per-person "today" agenda. Swaps the kiosk's unpackaged `custom:today-card`
      # for atomic-calendar-revive (in nixpkgs) limited to a single day, so the
      # whole dashboard stays declarable from Nix.
      calendarToday = cal: color: {
        type = "custom:atomic-calendar-revive";
        name = "Today";
        maxDaysToShow = 1;
        maxEventCount = 10;
        showLoader = false;
        showDate = false;
        showLocation = false;
        showCalendarName = false;
        showNoEventsForToday = true;
        hideFinishedEvents = true;
        disableEventLink = true;
        compactMode = true;
        hoursOnSameLine = true;
        eventDateFormat = "ddd MMM D";
        language = "en";
        entities = [
          {
            entity = cal;
            inherit color;
          }
        ];
        tap_action = {
          action = "navigate";
          navigation_path = "/nixos-home/week?kiosk";
        };
      };

      # Back-to-home chip that opens every sub-view (kiosk has no sidebar).
      backChip = {
        type = "custom:mushroom-chips-card";
        alignment = "start";
        chips = [
          {
            type = "template";
            icon = "mdi:arrow-left";
            content = "Back";
            tap_action = {
              action = "navigate";
              navigation_path = "/nixos-home/home?kiosk";
            };
          }
        ];
      };

      # A "clean this room" button → vacuum.clean_area for one cleaning_area_id.
      roomCard = name: icon: color: areaId: {
        type = "custom:mushroom-template-card";
        primary = name;
        inherit icon;
        icon_color = color;
        tap_action = {
          action = "perform-action";
          perform_action = "vacuum.clean_area";
          target.entity_id = "vacuum.vaccum";
          data.cleaning_area_id = [ areaId ];
        };
      };

      # A scene tile → scene.turn_on.
      sceneCard = name: icon: color: scene: {
        type = "custom:mushroom-template-card";
        primary = name;
        inherit icon;
        icon_color = color;
        tap_action = {
          action = "perform-action";
          perform_action = "scene.turn_on";
          target.entity_id = scene;
        };
      };

      # A needle gauge with optional unit / severity.
      gauge =
        {
          entity,
          name,
          min,
          max,
          unit ? null,
          severity ? null,
        }:
        {
          type = "gauge";
          inherit
            entity
            name
            min
            max
            ;
          needle = true;
        }
        // (if unit == null then { } else { inherit unit; })
        // (if severity == null then { } else { inherit severity; });

      # A Mushroom light card with the controls toggled per fixture.
      lightCard =
        {
          entity,
          name,
          icon,
          brightness ? true,
          colorTemp ? false,
          color ? false,
          useLightColor ? false,
          collapsible ? null,
        }:
        {
          type = "custom:mushroom-light-card";
          inherit entity name icon;
        }
        // (if useLightColor then { use_light_color = true; } else { })
        // (if brightness then { show_brightness_control = true; } else { })
        // (if colorTemp then { show_color_temp_control = true; } else { })
        // (if color then { show_color_control = true; } else { })
        // (if collapsible == null then { } else { collapsible_controls = collapsible; });

      homeView = {
        type = "sections";
        title = "Home";
        path = "home";
        max_columns = 4;

        badges = [
          {
            type = "custom:mushroom-template-badge";
            content = "{{ now().strftime('%a %b %d') }}";
            icon = "mdi:calendar";
          }
          {
            type = "entity";
            entity = "sensor.humidifier_humidity";
            name = "Humidity";
            show_state = true;
            show_name = true;
            show_icon = true;
          }
          {
            type = "entity";
            entity = "sensor.openweathermap_temperature";
            name = "Outside";
            show_state = true;
            show_name = true;
            show_icon = true;
          }
          {
            type = "custom:mushroom-template-badge";
            content = "{{ ((states('sensor.kingston_throop_n_next_arrival') | as_datetime - now()).total_seconds() / 60) | round(0, 'floor') | int }}m";
            icon = "mdi:subway-variant";
            color = "{% set m = ((states('sensor.kingston_throop_n_next_arrival') | as_datetime - now()).total_seconds() / 60) | round(0, 'floor') | int %}{% if m < 5 %}orange{% else %}primary{% endif %}";
          }
          {
            type = "entity";
            entity = "sensor.openweathermap_peak_rain_chance_12h";
            show_state = true;
            show_name = false;
            show_icon = true;
            visibility = [
              {
                condition = "numeric_state";
                entity = "sensor.openweathermap_peak_rain_chance_12h";
                above = 0;
              }
            ];
          }
          {
            type = "entity";
            entity = "sensor.openweathermap_uv_index";
            name = "UV";
            show_state = true;
            show_name = true;
            show_icon = true;
            visibility = [
              {
                condition = "numeric_state";
                entity = "sensor.openweathermap_uv_index";
                above = 5;
              }
            ];
          }
        ];

        sections = [
          # ── Meds alert (only renders when a dose is pending) ──────────────
          {
            type = "grid";
            cards = [
              {
                type = "conditional";
                conditions = [
                  {
                    entity = "binary_sensor.meds_needed";
                    state = "on";
                  }
                ];
                card = {
                  type = "markdown";
                  card_mod.style = {
                    "." = ''
                      ha-card {
                        background: linear-gradient(135deg, #c62828 0%, #b71c1c 100%);
                        color: #fff;
                        --card-primary-text-color: #fff;
                        --card-secondary-text-color: rgba(255, 255, 255, 0.85);
                        --ha-card-border-radius: 16px;
                        padding: 20px 24px;
                        font-size: 1.3em;
                        border: 2px solid rgba(255, 255, 255, 0.15);
                        box-shadow: 0 8px 32px rgba(183, 28, 28, 0.4);
                      }
                    '';
                    "ha-markdown$" = ''
                      .markdown-body h2 { margin: 0 0 8px 0; }
                      .markdown-body p { margin: 0; }
                    '';
                  };
                  content = ''
                    {% set morning = state_attr('binary_sensor.meds_needed', 'morning_pending') %}
                    {% set night   = state_attr('binary_sensor.meds_needed', 'night_pending') %}
                    {% if morning and night %}
                    ## <ha-icon icon="mdi:alert-circle"></ha-icon> Morning & Night Meds
                    **Both** still need to be taken today.
                    {% elif morning %}
                    ## <ha-icon icon="mdi:alert-circle"></ha-icon> Morning Meds
                    Not taken yet today.
                    {% elif night %}
                    ## <ha-icon icon="mdi:alert-circle"></ha-icon> Night Meds
                    Not taken yet tonight.
                    {% endif %}
                  '';
                };
              }
            ];
          }

          # ── Vacuum / humidifier consumable warnings (auto-populated chips) ─
          {
            type = "grid";
            column_span = 4;
            cards = [
              {
                type = "custom:auto-entities";
                card_param = "chips";
                show_empty = false;
                card = {
                  type = "custom:mushroom-chips-card";
                  alignment = "start";
                };
                filter.template = ''
                  [
                  {%- set entries = [
                    ('sensor.vaccum_filter_remaining', 'Filter', 'mdi:air-filter'),
                    ('sensor.vaccum_rolling_brush_remaining', 'Roller', 'mdi:rotate-3d-variant'),
                    ('sensor.vaccum_side_brush_remaining', 'Side brush', 'mdi:fan'),
                    ('sensor.vaccum_mopping_cloth_remaining', 'Mop', 'mdi:waves'),
                    ('sensor.vaccum_sensor_remaining', 'Sensors', 'mdi:eye-outline'),
                    ('sensor.vaccum_cleaning_tray_remaining', 'Tray', 'mdi:wiper'),
                  ] -%}
                  {%- for s, label, icon in entries -%}
                    {%- set t = state_attr(s, 'total_life_hours') | float(0) -%}
                    {%- if t > 0 -%}
                      {%- set pct = (states(s) | float(0) / t * 100) | int -%}
                      {%- if pct < 20 -%}
                        {'entity': '{{ s }}', 'type': 'template', 'icon': '{{ icon }}', 'icon_color': 'orange', 'content': '{{ label }} {{ pct }}%', 'tap_action': {'action': 'navigate', 'navigation_path': '/nixos-home/cleaning?kiosk'}},
                      {%- endif -%}
                    {%- endif -%}
                  {%- endfor -%}
                  {%- set sponge = states('sensor.humidifier_filter_lifetime') | float(100) -%}
                  {%- if sponge < 30 -%}
                    {'entity': 'sensor.humidifier_filter_lifetime', 'type': 'template', 'icon': 'mdi:air-filter', 'icon_color': 'orange', 'content': 'Sponge {{ sponge | int }}%', 'tap_action': {'action': 'navigate', 'navigation_path': '/nixos-home/cleaning?kiosk'}},
                  {%- endif -%}
                  {%- if is_state('binary_sensor.humidifier_low_water', 'on') -%}
                    {'entity': 'binary_sensor.humidifier_low_water', 'type': 'template', 'icon': 'mdi:water-alert', 'icon_color': 'red', 'content': 'Tank empty', 'tap_action': {'action': 'navigate', 'navigation_path': '/nixos-home/cleaning?kiosk'}},
                  {%- endif -%}
                  {%- set err = states('sensor.vaccum_error_message') | string -%}
                  {%- if err and err | length > 0 and err != 'unknown' and err != 'unavailable' -%}
                    {'entity': 'sensor.vaccum_error_message', 'type': 'template', 'icon': 'mdi:robot-vacuum-alert', 'icon_color': 'red', 'content': '{{ err }}', 'tap_action': {'action': 'navigate', 'navigation_path': '/nixos-home/cleaning?kiosk'}}
                  {%- endif -%}
                  ]
                '';
              }
            ];
          }

          # ── Fridge nudges (LLM-written reminders; hidden when empty) ───────
          {
            type = "grid";
            column_span = 4;
            cards = [
              {
                type = "markdown";
                content = ''
                  {% set lines = state_attr('sensor.fridge_nudges', 'lines') or [] %}{% if lines %}{% for line in lines %}- {{ line }}
                  {% endfor %}{% endif %}'';
                visibility = [
                  {
                    condition = "state";
                    entity = "sensor.fridge_nudges";
                    state_not = [
                      ""
                      "unknown"
                      "unavailable"
                    ];
                  }
                ];
                card_mod.style = {
                  "." = ''
                    ha-card {   background: linear-gradient(135deg, rgba(245,158,11,0.10), rgba(245,158,11,0.02)) !important;   border-radius: 16px !important;   border: none !important;   border-left: 4px solid var(--warning-color, #f59e0b) !important;   box-shadow: 0 2px 10px rgba(0,0,0,0.06) !important; }
                  '';
                  "ha-markdown$" = ''
                    .markdown-body { padding: 2px 6px; } ul { padding-left: 0; margin: 0; list-style: none; } li {   font-size: 1.25em;   font-weight: 500;   line-height: 1.45;   padding: 8px 4px 8px 32px;   position: relative;   letter-spacing: -0.005em;   border-bottom: 1px solid rgba(245,158,11,0.12); } li:last-child { border-bottom: none; } li::before {   content: "";   position: absolute;   left: 8px;   top: 0.85em;   width: 10px;   height: 10px;   border-radius: 50%;   background: var(--warning-color, #f59e0b);   box-shadow: 0 0 10px rgba(245,158,11,0.5); }
                  '';
                };
              }
            ];
          }

          # ── Finn: presence, today's calendar, chores ──────────────────────
          {
            type = "grid";
            cards = [
              {
                type = "heading";
                heading = "Finn";
                heading_style = "title";
                badges = [
                  {
                    type = "entity";
                    show_state = true;
                    show_icon = true;
                    entity = "sensor.nougat_battery_level";
                    color = "state";
                  }
                ];
              }
              {
                type = "custom:mushroom-person-card";
                entity = "person.finn";
                fill_container = false;
                secondary_info = "last-changed";
                primary_info = "state";
                icon_type = "entity-picture";
              }
              {
                type = "custom:mushroom-person-card";
                entity = "person.emily";
                fill_container = false;
                secondary_info = "last-changed";
                primary_info = "state";
                icon_type = "entity-picture";
              }
              (calendarToday "calendar.finn" "#f97316")
              {
                display_order = "duedate_asc";
                type = "todo-list";
                entity = "todo.chores";
                hide_create = false;
                hide_completed = true;
                hide_section_headers = true;
              }
            ];
          }

          # ── Ciara: presence, today's calendar, shopping list ──────────────
          {
            type = "grid";
            cards = [
              {
                type = "heading";
                heading = "Ciara";
                heading_style = "title";
                badges = [
                  {
                    type = "entity";
                    show_state = true;
                    show_icon = true;
                    entity = "sensor.ciaras_iphone_battery_level";
                    color = "state";
                  }
                ];
              }
              {
                type = "custom:mushroom-person-card";
                entity = "person.ciara";
                primary_info = "state";
                secondary_info = "last-changed";
                icon_type = "entity-picture";
              }
              {
                type = "custom:mushroom-person-card";
                entity = "person.holland";
                primary_info = "state";
                secondary_info = "last-changed";
                icon_type = "entity-picture";
              }
              (calendarToday "calendar.ciara" "#10b981")
              {
                display_order = "none";
                type = "todo-list";
                entity = "todo.foodtown";
                hide_completed = true;
                hide_section_headers = true;
              }
            ];
          }

          # ── Home: quick toggles, media, weather, subway, cleaning, lights ─
          {
            type = "grid";
            cards = [
              {
                type = "heading";
                heading = "Home";
                heading_style = "title";
                badges = [
                  {
                    type = "entity";
                    entity = "vacuum.vaccum";
                    color = "state";
                    show_state = true;
                  }
                ];
              }
              {
                type = "custom:mushroom-chips-card";
                alignment = "end";
                chips = [
                  {
                    type = "template";
                    icon = "mdi:calendar-week";
                    icon_color = "blue";
                    content = "Week";
                    tap_action = {
                      action = "navigate";
                      navigation_path = "/nixos-home/week?kiosk";
                    };
                  }
                  {
                    type = "template";
                    entity = "input_boolean.guest_mode";
                    icon = "mdi:account-group";
                    icon_color = "{{ 'indigo' if is_state('input_boolean.guest_mode', 'on') else 'disabled' }}";
                    content = "Guest · {{ 'On' if is_state('input_boolean.guest_mode', 'on') else 'Off' }}";
                    tap_action.action = "toggle";
                  }
                  {
                    type = "template";
                    entity = "input_boolean.welcome_home_lights_enabled";
                    icon = "mdi:home-import-outline";
                    icon_color = "{{ 'amber' if is_state('input_boolean.welcome_home_lights_enabled', 'on') else 'disabled' }}";
                    content = "Welcome · {{ 'On' if is_state('input_boolean.welcome_home_lights_enabled', 'on') else 'Off' }}";
                    tap_action.action = "toggle";
                  }
                  {
                    type = "template";
                    entity = "input_boolean.vacuum_auto_skip_today";
                    icon = "mdi:robot-vacuum-off";
                    icon_color = "{{ 'red' if is_state('input_boolean.vacuum_auto_skip_today', 'on') else 'disabled' }}";
                    content = "Skip vac · {{ 'On' if is_state('input_boolean.vacuum_auto_skip_today', 'on') else 'Off' }}";
                    tap_action.action = "toggle";
                  }
                  {
                    type = "template";
                    entity = "input_boolean.living_room_appletv_dim_enabled";
                    icon = "mdi:television-shimmer";
                    icon_color = "{{ 'purple' if is_state('input_boolean.living_room_appletv_dim_enabled', 'on') else 'disabled' }}";
                    content = "TV dim · {{ 'On' if is_state('input_boolean.living_room_appletv_dim_enabled', 'on') else 'Off' }}";
                    tap_action.action = "toggle";
                  }
                  {
                    type = "template";
                    icon = "mdi:cart";
                    icon_color = "teal";
                    content = "Reorder";
                    tap_action = {
                      action = "navigate";
                      navigation_path = "/nixos-reorder/reorder?kiosk";
                    };
                  }
                ];
              }
              {
                type = "media-control";
                entity = "media_player.living_room";
                grid_options = {
                  columns = 12;
                  rows = "auto";
                };
                visibility = [
                  {
                    condition = "state";
                    entity = "media_player.living_room";
                    state_not = "off";
                  }
                ];
              }
              {
                type = "custom:clock-weather-card";
                entity = "weather.openweathermap";
              }
              {
                type = "markdown";
                content = ''
                  {% set next = states('sensor.kingston_throop_n_next_arrival') | as_datetime %}
                  {% set second = states('sensor.kingston_throop_n_second_arrival') | as_datetime %}
                  {% set third = states('sensor.kingston_throop_n_third_arrival') | as_datetime %}
                  {% set n = ((next - now()).total_seconds() / 60) | round(0, 'floor') | int if next else '--' %}
                  {% set s = ((second - now()).total_seconds() / 60) | round(0, 'floor') | int if second else '--' %}
                  {% set t = ((third - now()).total_seconds() / 60) | round(0, 'floor') | int if third else '--' %}

                  ### <span>C</span> ↑ Manhattan

                  # **{{ n }}**<small> min</small> &nbsp;·&nbsp; **{{ s }}** &nbsp;·&nbsp; **{{ t }}**'';
                card_mod.style."ha-markdown$" = ''
                  h3 span {
                    display: inline-flex;
                    align-items: center;
                    justify-content: center;
                    width: 1.6em;
                    height: 1.6em;
                    border-radius: 50%;
                    background-color: #0039A6;
                    color: #fff;
                    font-weight: 700;
                    font-size: 0.85em;
                    vertical-align: middle;
                    margin-right: 6px;
                  }
                  h1 {
                    font-variant-numeric: tabular-nums;
                    letter-spacing: -0.02em;
                  }
                '';
              }
              {
                type = "tile";
                entity = "vacuum.vaccum";
                name = "Vacuum";
                features_position = "bottom";
                features = [
                  {
                    type = "vacuum-commands";
                    commands = [
                      "start_pause"
                      "return_home"
                      "locate"
                    ];
                  }
                ];
                hold_action = {
                  action = "navigate";
                  navigation_path = "/nixos-home/cleaning?kiosk";
                };
              }
              {
                type = "tile";
                entity = "humidifier.humidifier";
                name = "Humidifier";
                features_position = "bottom";
                features = [ { type = "target-humidity"; } ];
              }
              {
                type = "custom:mini-graph-card";
                name = "Inside 24h";
                entities = [
                  {
                    entity = "sensor.humidifier_humidity";
                    name = "Humidity";
                    color = "#3b82f6";
                  }
                  {
                    entity = "sensor.humidifier_temperature";
                    name = "Temp";
                    color = "#f59e0b";
                    y_axis = "secondary";
                    show_state = true;
                  }
                ];
                hours_to_show = 24;
                points_per_hour = 2;
                line_width = 2;
                height = 90;
                show = {
                  name = true;
                  icon = false;
                  state = true;
                  legend = false;
                  extrema = false;
                  labels = false;
                  labels_secondary = false;
                  fill = "fade";
                };
                animate = false;
                smoothing = true;
              }
              {
                type = "heading";
                heading = "Lights";
                heading_style = "subtitle";
                icon = "mdi:lightbulb-multiple-outline";
              }
              {
                type = "custom:mushroom-chips-card";
                alignment = "center";
                chips = [
                  {
                    type = "template";
                    icon = "mdi:lightbulb-off";
                    icon_color = "disabled";
                    content = "All off";
                    tap_action = {
                      action = "perform-action";
                      perform_action = "light.turn_off";
                      target.entity_id = "all";
                    };
                  }
                  {
                    type = "entity";
                    entity = "scene.living_room_bright";
                    content_info = "name";
                    name = "Bright";
                    icon = "mdi:weather-sunny";
                    icon_color = "amber";
                    tap_action = {
                      action = "perform-action";
                      perform_action = "scene.turn_on";
                      target.entity_id = "scene.living_room_bright";
                    };
                  }
                  {
                    type = "entity";
                    entity = "scene.living_room_soho";
                    content_info = "name";
                    name = "Soho";
                    icon = "mdi:lamp";
                    icon_color = "deep-orange";
                    tap_action = {
                      action = "perform-action";
                      perform_action = "scene.turn_on";
                      target.entity_id = "scene.living_room_soho";
                    };
                  }
                  {
                    type = "entity";
                    entity = "scene.living_room_relax";
                    content_info = "name";
                    name = "Relax";
                    icon = "mdi:sofa";
                    icon_color = "orange";
                    tap_action = {
                      action = "perform-action";
                      perform_action = "scene.turn_on";
                      target.entity_id = "scene.living_room_relax";
                    };
                  }
                  {
                    type = "entity";
                    entity = "scene.living_room_nightlight";
                    content_info = "name";
                    name = "Night";
                    icon = "mdi:weather-night";
                    icon_color = "indigo";
                    tap_action = {
                      action = "perform-action";
                      perform_action = "scene.turn_on";
                      target.entity_id = "scene.living_room_nightlight";
                    };
                  }
                  {
                    type = "template";
                    icon = "mdi:dots-horizontal";
                    icon_color = "grey";
                    content = "More";
                    tap_action = {
                      action = "navigate";
                      navigation_path = "/nixos-home/lights?kiosk";
                    };
                  }
                ];
              }
            ];
          }
        ];
      };

      # ── Cleaning sub-view (vacuum control + consumable upkeep) ────────────
      cleaningView = {
        type = "sections";
        title = "Cleaning";
        icon = "mdi:robot-vacuum-variant";
        path = "cleaning";
        max_columns = 4;
        sections = [
          {
            type = "grid";
            cards = [
              backChip
              {
                type = "heading";
                heading = "Vacuum";
                heading_style = "title";
                icon = "mdi:robot-vacuum-variant";
                badges = [
                  {
                    type = "entity";
                    entity = "vacuum.vaccum";
                    color = "state";
                    show_state = true;
                  }
                  {
                    type = "entity";
                    entity = "sensor.vaccum_battery";
                    color = "state";
                  }
                ];
              }
              {
                type = "tile";
                entity = "vacuum.vaccum";
                name = "Vacuum";
                features_position = "bottom";
                features = [
                  {
                    type = "vacuum-commands";
                    commands = [
                      "start_pause"
                      "return_home"
                      "locate"
                      "stop"
                    ];
                  }
                ];
                grid_options = {
                  columns = 12;
                  rows = "auto";
                };
              }
              {
                type = "heading";
                heading = "Clean a room";
                heading_style = "subtitle";
                icon = "mdi:home-search";
              }
              {
                type = "grid";
                columns = 2;
                square = false;
                cards = [
                  (roomCard "Living Room" "mdi:sofa" "blue" "living_room")
                  (roomCard "Kitchen" "mdi:stove" "red" "kitchen")
                  (roomCard "Bedroom" "mdi:bed" "purple" "bedroom")
                  (roomCard "Office" "mdi:office-building" "amber" "office")
                ];
              }
              {
                type = "heading";
                heading = "Schedule";
                heading_style = "subtitle";
                icon = "mdi:calendar-clock";
              }
              {
                type = "tile";
                entity = "input_boolean.vacuum_auto_skip_today";
                name = "Skip today";
                grid_options = {
                  columns = 6;
                  rows = "auto";
                };
              }
              {
                type = "custom:mushroom-template-card";
                primary = "Last auto-run";
                secondary = "{% set t = states('input_datetime.vacuum_last_auto_run') %}{% if t == '2020-01-01 00:00:00' %}Never{% else %}{{ (t | as_datetime).strftime('%a %b %d %H:%M') }}{% endif %}";
                icon = "mdi:history";
                icon_color = "grey";
              }
            ];
          }
          {
            type = "grid";
            cards = [
              {
                type = "heading";
                heading = "Vacuum upkeep";
                heading_style = "title";
                icon = "mdi:wrench";
              }
              {
                type = "grid";
                columns = 2;
                square = false;
                cards = [
                  (gauge {
                    entity = "sensor.vaccum_battery";
                    name = "Battery";
                    min = 0;
                    max = 100;
                    severity = {
                      green = 50;
                      yellow = 20;
                      red = 0;
                    };
                  })
                  (gauge {
                    entity = "sensor.vaccum_water_level";
                    name = "Water";
                    min = 0;
                    max = 100;
                    severity = {
                      green = 50;
                      yellow = 20;
                      red = 0;
                    };
                  })
                  (gauge {
                    entity = "sensor.vaccum_filter_remaining";
                    name = "Filter";
                    unit = "h";
                    min = 0;
                    max = 360;
                    severity = {
                      green = 180;
                      yellow = 72;
                      red = 0;
                    };
                  })
                  (gauge {
                    entity = "sensor.vaccum_rolling_brush_remaining";
                    name = "Roller";
                    unit = "h";
                    min = 0;
                    max = 360;
                    severity = {
                      green = 180;
                      yellow = 72;
                      red = 0;
                    };
                  })
                  (gauge {
                    entity = "sensor.vaccum_side_brush_remaining";
                    name = "Side brush";
                    unit = "h";
                    min = 0;
                    max = 180;
                    severity = {
                      green = 90;
                      yellow = 36;
                      red = 0;
                    };
                  })
                  (gauge {
                    entity = "sensor.vaccum_mopping_cloth_remaining";
                    name = "Mop";
                    unit = "h";
                    min = 0;
                    max = 180;
                    severity = {
                      green = 90;
                      yellow = 36;
                      red = 0;
                    };
                  })
                  (gauge {
                    entity = "sensor.vaccum_sensor_remaining";
                    name = "Sensors";
                    unit = "h";
                    min = 0;
                    max = 60;
                    severity = {
                      green = 30;
                      yellow = 12;
                      red = 0;
                    };
                  })
                  (gauge {
                    entity = "sensor.vaccum_cleaning_tray_remaining";
                    name = "Tray";
                    unit = "h";
                    min = 0;
                    max = 30;
                    severity = {
                      green = 15;
                      yellow = 6;
                      red = 0;
                    };
                  })
                ];
              }
              {
                type = "heading";
                heading = "Humidifier";
                heading_style = "title";
                icon = "mdi:air-humidifier";
              }
              {
                type = "tile";
                entity = "humidifier.humidifier";
                name = "Humidifier";
                features_position = "bottom";
                features = [ { type = "target-humidity"; } ];
                grid_options = {
                  columns = 12;
                  rows = "auto";
                };
              }
              {
                type = "grid";
                columns = 2;
                square = false;
                cards = [
                  (gauge {
                    entity = "sensor.humidifier_filter_lifetime";
                    name = "Sponge";
                    unit = "%";
                    min = 0;
                    max = 100;
                    severity = {
                      green = 50;
                      yellow = 20;
                      red = 0;
                    };
                  })
                  (gauge {
                    entity = "sensor.humidifier_humidity";
                    name = "Humidity";
                    unit = "%";
                    min = 30;
                    max = 80;
                  })
                ];
              }
              {
                type = "tile";
                entity = "binary_sensor.humidifier_low_water";
                name = "Tank water";
                grid_options = {
                  columns = 6;
                  rows = "auto";
                };
              }
              {
                type = "tile";
                entity = "binary_sensor.humidifier_water_tank_lifted";
                name = "Tank seated";
                grid_options = {
                  columns = 6;
                  rows = "auto";
                };
              }
            ];
          }
        ];
      };

      # ── Lights sub-view (bulbs, living-room scenes, fairy lights) ─────────
      lightsView = {
        type = "sections";
        title = "Lights";
        icon = "mdi:lightbulb-multiple";
        path = "lights";
        max_columns = 4;
        sections = [
          {
            type = "grid";
            cards = [
              backChip
              {
                type = "heading";
                heading = "Bulbs";
                heading_style = "title";
                icon = "mdi:lightbulb-group";
              }
              {
                type = "heading";
                heading = "Living Room";
                heading_style = "subtitle";
                icon = "mdi:sofa-outline";
              }
              {
                type = "grid";
                columns = 2;
                square = false;
                cards = [
                  (lightCard {
                    entity = "light.living_room";
                    name = "Living Room";
                    icon = "mdi:sofa-outline";
                    useLightColor = true;
                    colorTemp = true;
                    color = true;
                    collapsible = false;
                  })
                  (lightCard {
                    entity = "light.smart_led_bulb_2";
                    name = "Corner Lamp";
                    icon = "mdi:floor-lamp";
                    useLightColor = true;
                  })
                ];
              }
              {
                type = "heading";
                heading = "Bedroom";
                heading_style = "subtitle";
                icon = "mdi:bed";
              }
              {
                type = "grid";
                columns = 2;
                square = false;
                cards = [
                  (lightCard {
                    entity = "light.smart_led_bulb";
                    name = "Bedside";
                    icon = "mdi:bed-outline";
                    useLightColor = true;
                  })
                  (lightCard {
                    entity = "light.bedroom_overhead";
                    name = "Overhead";
                    icon = "mdi:ceiling-light-outline";
                  })
                ];
              }
              {
                type = "heading";
                heading = "Office";
                heading_style = "subtitle";
                icon = "mdi:office-building";
              }
              (lightCard {
                entity = "light.bedroom_overhead_2";
                name = "Overhead";
                icon = "mdi:ceiling-light-outline";
              })
            ];
          }
          {
            type = "grid";
            cards = [
              {
                type = "heading";
                heading = "Living Room Scenes";
                heading_style = "title";
                icon = "mdi:palette";
              }
              {
                type = "heading";
                heading = "Bright";
                heading_style = "subtitle";
                icon = "mdi:weather-sunny";
              }
              {
                type = "grid";
                columns = 2;
                square = false;
                cards = [
                  (sceneCard "Bright" "mdi:weather-sunny" "amber" "scene.living_room_bright")
                  (sceneCard "Energize" "mdi:lightning-bolt" "yellow" "scene.living_room_energize")
                  (sceneCard "Concentrate" "mdi:brain" "cyan" "scene.living_room_concentrate")
                  (sceneCard "Natural" "mdi:white-balance-sunny" "white" "scene.living_room_natural_light")
                ];
              }
              {
                type = "heading";
                heading = "Warm";
                heading_style = "subtitle";
                icon = "mdi:lamp";
              }
              {
                type = "grid";
                columns = 2;
                square = false;
                cards = [
                  (sceneCard "Soho" "mdi:lamp" "deep-orange" "scene.living_room_soho")
                  (sceneCard "Read" "mdi:book-open-variant" "orange" "scene.living_room_read")
                  (sceneCard "Relax" "mdi:sofa" "orange" "scene.living_room_relax")
                  (sceneCard "Candle" "mdi:candle" "deep-orange" "scene.living_room_corner_candle")
                  (sceneCard "Fireplace" "mdi:fireplace" "red" "scene.living_room_fireplace")
                ];
              }
              {
                type = "heading";
                heading = "Dim & Sleep";
                heading_style = "subtitle";
                icon = "mdi:weather-night";
              }
              {
                type = "grid";
                columns = 2;
                square = false;
                cards = [
                  (sceneCard "Rest" "mdi:bed-outline" "purple" "scene.living_room_rest")
                  (sceneCard "Night" "mdi:weather-night" "indigo" "scene.living_room_nightlight")
                  (sceneCard "Moonlight" "mdi:moon-waning-crescent" "indigo" "scene.living_room_moonlight")
                ];
              }
            ];
          }
          {
            type = "grid";
            cards = [
              {
                type = "heading";
                heading = "Fairy Lights";
                heading_style = "title";
                icon = "mdi:string-lights";
              }
              (lightCard {
                entity = "light.fairy_lights";
                name = "Fairy";
                icon = "mdi:string-lights";
                useLightColor = true;
                color = true;
                collapsible = false;
              })
              {
                type = "tile";
                entity = "select.fairy_lights_preset";
                name = "Preset";
                icon = "mdi:palette-swatch";
                features_position = "bottom";
                features = [ { type = "select-options"; } ];
              }
            ];
          }
        ];
      };

      # ── Week sub-view (two-week multi-person planner) ─────────────────────
      weekView = {
        type = "sections";
        title = "Week";
        icon = "mdi:calendar-week";
        path = "week";
        max_columns = 2;
        sections = [
          {
            type = "grid";
            column_span = 2;
            cards = [
              backChip
              {
                type = "custom:atomic-calendar-revive";
                name = "Two Weeks";
                maxDaysToShow = 2;
                maxEventCount = 40;
                softLimit = 5;
                showLoader = false;
                disableEventLink = true;
                showCalendarName = true;
                showNoEventsForToday = true;
                hideFinishedEvents = true;
                defaultMode = "Planner";
                eventDateFormat = "ddd MMM D";
                hideDuplicates = true;
                showMultiDay = true;
                showMultiDayEventParts = true;
                titleLength = 60;
                plannerRollingWeek = true;
                compactMode = true;
                showTimeRemaining = false;
                hoursOnSameLine = true;
                language = "en";
                entities = [
                  {
                    entity = "calendar.finn";
                    name = "Finn";
                    color = "#f97316";
                  }
                  {
                    entity = "calendar.ciara";
                    name = "Ciara";
                    color = "#10b981";
                  }
                ];
                grid_options.columns = "full";
              }
            ];
          }
        ];
      };

      homeDashboard = yamlFormat.generate "lovelace-home.yaml" {
        title = "Home";
        views = [
          homeView
          cleaningView
          lightsView
          weekView
        ];
      };
    in
    {
      # Single source of truth for this host's frontend resources. Declaring any
      # of these emits lovelace.resources (yaml resource_mode), so EVERY custom:
      # card used by any dashboard on iot must be in this list. card-mod MUST stay
      # here or all card_mod: styling is silently ignored.
      services.home-assistant.customLovelaceModules = with pkgs.home-assistant-custom-lovelace-modules; [
        mushroom
        card-mod
        auto-entities
        button-card
        mini-graph-card
        clock-weather-card
        atomic-calendar-revive
        kiosk-mode # powers the `?kiosk` query param (hides header/sidebar)
        # + today-card (custom derivation) if the kiosk's today-card is ever
        #   migrated verbatim; this dashboard swaps it for atomic-calendar-revive.
      ];

      services.home-assistant.config.lovelace.dashboards.nixos-home = {
        mode = "yaml";
        filename = "${homeDashboard}";
        title = "Home";
        icon = "mdi:home";
        show_in_sidebar = true;
      };

      # Reload on rebuild when the generated dashboard changes (no manual push).
      systemd.services.home-assistant.reloadTriggers = [ homeDashboard ];
    };
}

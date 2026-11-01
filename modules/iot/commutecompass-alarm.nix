# Home Assistant glue for CommuteCompass wake/nap alarms (link owns ringing).
#
# iOS Shortcuts recipe (HA actions require an authenticated HA connection):
# - Run the alarm-sync shortcut daily at 21:00 and on charger connect.
# - Add a "Nap" home-screen shortcut: press input_button.commute_nap_30 via
#   the HA action, wait 5 seconds, then run alarm sync.
# - Alarm sync: read the master switch, skipped timestamp and next-alarm sensor.
#   Validate the schedule BEFORE modifying Clock. Convert the offset-bearing
#   timestamp to phone-local time (HA/link use America/New_York). Clock alarms
#   have a time but no date: only sync if the requested instant is the NEXT
#   occurrence of that local time; otherwise warn and keep the existing backup.
#   Reject ambiguous DST times unless the next occurrence matches the instant.
# - Snapshot OLD Clock alarms labelled "CommuteCompass". Create the new labelled
#   alarm FIRST, verify creation/enabled time, then delete ONLY the old alarms
#   (exclude the newly created alarm by identity). If any step fails, preserve
#   the old backup and do not confirm. Finally call input_datetime.set_datetime
#   on input_datetime.commute_alarm_confirmed with the planned timestamp, not
#   the shortcut execution time. Enable "Run Immediately" on the automations.
# - Explicit master-off: delete owned Clock alarms when this shortcut runs.
#   For skip, delete owned alarms only if the skipped timestamp matches the
#   last phone-confirmed alarm, then sync a valid replacement if present.
#   Never touch unrelated alarms. Unknown/unavailable HA data alone is NOT a
#   deletion instruction; a persisted old skip is not a new cancellation.
#   Skip/off in HA cannot remotely modify Clock: the phone applies them only
#   when the shortcut runs; run it manually after changing either in HA.
#
# The master switch deliberately has no `initial`: HA restores the user's
# on/off choice. On first installation, turn it on once in HA (a brand-new
# input_boolean otherwise defaults off). Datetime helpers also restore state;
# UTC text helpers are authoritative and have no `initial`; missing text is
# unknown, NEVER a reason to fall back to naive display datetimes. Epoch zero
# (1970-01-01T00:00:00+00:00) explicitly clears a cap/nap. Local datetime helpers
# are display/legacy only. The daemon owns input_text.commute_alarm_handled_at:
# write the ORIGINAL offset-bearing deadline only after successful audio start,
# including after snooze; a heartbeat alone does not acknowledge playback.
#
# Legacy pull-model contract is retained: `commutecompass tomorrow` POSTs
# `alarm_at` to script.commute_set_tomorrow_alarm. The field is not called
# `datetime`, which HA's Jinja namespace reserves for the Python module.
{
  configurations.nixos.iot.module =
    let
      utcSentinel = "1970-01-01T00:00:00+00:00";
      # Text is authoritative across DST folds/restarts. Write it first, then
      # the local display helper; never reconstruct an instant from the latter.
      writeInstant = textId: displayId: timestamp: [
        {
          service = "input_text.set_value";
          target.entity_id = "input_text.commute_${textId}";
          data.value = "{{ (${timestamp}) | timestamp_custom('%Y-%m-%dT%H:%M:%S+00:00', false) }}";
        }
        {
          service = "input_datetime.set_datetime";
          target.entity_id = "input_datetime.commute_${displayId}";
          data.timestamp = "{{ ${timestamp} }}";
        }
      ];
      # Shared by the sensor state, availability and kind. Compare instants,
      # not ISO strings: offsets/DST must not change ordering or skip matching.
      nextAlarm = ''
        {% set skipped = as_timestamp(states('input_text.commute_alarm_skipped_utc'), 0) %}
        {% set ns = namespace(alarms=[]) %}
        {% for kind in ['wake', 'nap'] %}
          {% set at = as_timestamp(states('input_text.commute_' ~ kind ~ '_utc'), 0) %}
          {% if at > as_timestamp(now()) and at != skipped %}
            {% set ns.alarms = ns.alarms + [{'at': at, 'kind': kind}] %}
          {% endif %}
        {% endfor %}
        {% set alarms = ns.alarms | sort(attribute='at') %}
      '';
    in
    {
      services.home-assistant.config = {
        input_datetime = {
          commute_tomorrow_alarm = {
            name = "Commute — tomorrow alarm";
            has_date = true;
            has_time = true;
            icon = "mdi:alarm";
          };
        }
        // builtins.listToAttrs (
          map
            (id: {
              name = "commute_${id}";
              value = {
                name = "Commute — ${id}";
                has_date = true;
                has_time = true;
                icon = "mdi:alarm";
              };
            })
            [
              "wake_at"
              "next_prep_at"
              "nap_at"
              "alarm_skipped_at"
              "alarm_heartbeat"
              "alarm_confirmed"
            ]
        );
        input_text = {
          commute_next_event = {
            name = "Commute — next event";
            max = 255;
          };
          # Restored JSON epoch-second ledger; never set `initial`. Sixteen
          # deadlines fit HA's 255-character limit. Older evicted entries are
          # already outside the fallback's two-minute catch-up window.
          commute_alarm_fallback_claims = {
            name = "Commute — fallback claims";
            max = 255;
          };
        }
        // builtins.listToAttrs (
          map
            (id: {
              name = "commute_${id}";
              value = {
                name = "Commute — ${id}";
                max = 64;
              };
            })
            [
              "wake_utc"
              "nap_utc"
              "alarm_skipped_utc"
              "next_prep_utc"
              "alarm_handled_at"
            ]
        );
        input_boolean = {
          commute_alarm_enabled = {
            name = "Commute — alarm enabled";
            icon = "mdi:alarm-check";
          };
          # Python sets on for audio start/update failure; only a successful
          # audio start clears it. A live heartbeat alone cannot prove sound.
          commute_alarm_audio_failed = {
            name = "Commute — alarm audio failed";
            icon = "mdi:volume-off";
          };
        };
        input_button = {
          commute_alarm_stop.name = "Commute — stop alarm";
          commute_alarm_snooze.name = "Commute — snooze alarm";
          commute_nap_30.name = "Commute — nap 30 minutes";
        };
        input_select.commute_alarm_state = {
          name = "Commute — alarm state";
          options = [
            "idle"
            "ringing"
            "snoozed"
          ];
        };
        template = [
          {
            sensor = [
              {
                name = "Commute Next Alarm";
                unique_id = "commute_next_alarm";
                device_class = "timestamp";
                availability = nextAlarm + ''
                  {{ is_state('input_boolean.commute_alarm_enabled', 'on') and alarms | count > 0 }}
                '';
                state = nextAlarm + ''
                  {{ as_datetime(alarms[0].at).isoformat() if alarms | count > 0 else none }}
                '';
                attributes = {
                  kind = nextAlarm + "{{ alarms[0].kind if alarms | count > 0 else none }}";
                  event = "{{ states('input_text.commute_next_event') }}";
                };
              }
            ];
          }
        ];
      };

      iotHass.nixScripts = [
        {
          id = "commute_alarm_fallback_check";
          alias = "Commute — claim fallback deadline";
          # All callers serialize here; ledger is written BEFORE any send.
          # At-most-once delivery: a failed notify is not retried. HA restores
          # helpers on ordinary restarts; abrupt loss before restore-state is
          # flushed cannot offer transactional exactly-once guarantees.
          mode = "queued";
          max = 10;
          sequence = [
            {
              condition = "template";
              value_template = "{{ states('input_boolean.commute_alarm_enabled') in ['on', 'off'] }}";
            }
            {
              variables = {
                claims = ''
                  {% set raw = states('input_text.commute_alarm_fallback_claims') %}
                  {{ raw[3:] | from_json([]) if raw.startswith('v1:') else [] }}
                '';
                enabled = "{{ is_state('input_boolean.commute_alarm_enabled', 'on') }}";
                skipped = "{{ as_timestamp(states('input_text.commute_alarm_skipped_utc'), 0) | int }}";
                unhealthy = ''
                  {{ as_timestamp(now()) - as_timestamp(states('input_datetime.commute_alarm_heartbeat'), 0) > 180
                     or is_state('input_boolean.commute_alarm_audio_failed', 'on') }}
                '';
              };
            }
            {
              variables.selection = ''
                {% set ns = namespace(claims=claims | list, alert=false) %}
                {% set now_ts = as_timestamp(now()) %}
                {% for kind in ['wake', 'nap', 'alarm_skipped'] %}
                  {% set at = as_timestamp(states('input_text.commute_' ~ kind ~ '_utc'), 0) | int %}
                  {% set age = now_ts - at %}
                  {% set due = 60 <= age < 180 %}
                  {% if at > 86400 and at not in ns.claims and (not enabled or at == skipped or due) %}
                    {% set ns.claims = ns.claims + [at] %}
                    {% set acknowledged = as_timestamp(states('input_text.commute_alarm_handled_at'), 0) | int == at %}
                    {% if enabled and at != skipped and due and (unhealthy or not acknowledged) %}
                      {% set ns.alert = true %}
                    {% endif %}
                  {% endif %}
                {% endfor %}
                {{ {'claims': ns.claims[-16:], 'alert': ns.alert} }}
              '';
            }
            {
              condition = "template";
              value_template = "{{ selection.claims != claims }}";
            }
            {
              service = "input_text.set_value";
              target.entity_id = "input_text.commute_alarm_fallback_claims";
              # Prefix prevents HA's native-template conversion turning a
              # JSON array string into a list rejected by input_text.
              data.value = "{{ 'v1:' ~ (selection.claims | to_json) }}";
            }
            {
              condition = "template";
              value_template = ''
                {{ selection.alert and is_state('input_boolean.commute_alarm_enabled', 'on')
                   and as_timestamp(states('input_text.commute_alarm_skipped_utc'), 0) | int == skipped }}
              '';
            }
            {
              service = "notify.iphone";
              data = {
                message = "link alarm offline — WAKE UP";
                data.push.sound = {
                  name = "default";
                  critical = 1;
                  volume = 1.0;
                };
              };
            }
          ];
        }
        {
          id = "commute_set_tomorrow_alarm";
          alias = "Commute — set tomorrow alarm";
          description = ''
            Receives a single `alarm_at` variable (ISO-8601, NYC-local with
            offset) from `commutecompass tomorrow` and stores it in
            input_datetime.commute_tomorrow_alarm. The iOS Shortcut polls
            that helper later and creates the on-device alarm.
          '';
          mode = "single";
          icon = "mdi:alarm-plus";
          fields = {
            alarm_at = {
              description = "ISO-8601 datetime to wake up at.";
              example = "2026-05-26T05:42:00-04:00";
              required = true;
              selector.text = { };
            };
          };
          sequence = [
            {
              service = "input_datetime.set_datetime";
              target.entity_id = "input_datetime.commute_tomorrow_alarm";
              data.datetime = "{{ alarm_at }}";
            }
          ];
        }
        {
          id = "commute_publish_alarm";
          alias = "Commute — publish alarm";
          mode = "queued";
          fields = {
            wake_at = {
              description = "ISO-8601 wake datetime, with offset.";
              required = true;
              selector.text = { };
            };
            next_prep_at = {
              description = "ISO-8601 hard nap cap (next prep minus wake lead), or empty to clear.";
              selector.text = { };
            };
            next_event = {
              description = "Next event title, or empty.";
              selector.text = { };
            };
          };
          sequence = [
            {
              variables = {
                incoming = "{{ as_timestamp(wake_at) }}";
                existing = "{{ as_timestamp(states('input_text.commute_wake_utc'), 0) }}";
                prep = "{{ as_timestamp(next_prep_at) if next_prep_at | default(\"\", true) | trim else 0 }}";
              };
            }
            {
              choose = [
                {
                  # Preserve today's just-due wake during ordinary next-day
                  # rollover, until the daemon/fallback has had its window.
                  # A later publisher timer installs tomorrow; cap/event still
                  # update now. Explicit same-day replans remain authoritative.
                  conditions = [
                    {
                      condition = "template";
                      value_template = ''
                        {% set rollover = as_local(as_datetime(incoming)).date() > as_local(as_datetime(existing)).date() %}
                        {% set preserve = is_state('input_boolean.commute_alarm_enabled', 'on')
                           and existing != as_timestamp(states('input_text.commute_alarm_skipped_utc'), 0)
                           and 0 <= as_timestamp(now()) - existing <= 180 and rollover %}
                        {{ not preserve }}
                      '';
                    }
                  ];
                  sequence = writeInstant "wake_utc" "wake_at" "incoming";
                }
              ];
            }
          ]
          ++ writeInstant "next_prep_utc" "next_prep_at" "prep"
          ++ [
            {
              service = "input_text.set_value";
              target.entity_id = "input_text.commute_next_event";
              data.value = "{{ (next_event | default('', true) | string)[:255] }}";
            }
          ];
        }
        {
          id = "commute_nap";
          alias = "Commute — set nap alarm";
          mode = "queued";
          fields.minutes = {
            description = "Nap duration in minutes (default 30).";
            default = 30;
            selector.number = {
              min = 1;
              max = 1440;
              mode = "box";
            };
          };
          sequence = [
            {
              # Housekeeping shares this queue with nap writes and rechecks
              # current state/deadline after waiting; it cannot clear a new nap.
              choose = [
                {
                  conditions = [
                    {
                      condition = "template";
                      value_template = "{{ cleanup | default(false) }}";
                    }
                  ];
                  sequence = [
                    {
                      choose = [
                        {
                          conditions = [
                            {
                              condition = "template";
                              value_template = ''
                                {% set nap = as_timestamp(states('input_text.commute_nap_utc'), 0) %}
                                {{ nap > 0 and nap + 1200 <= as_timestamp(now())
                                   and is_state('input_select.commute_alarm_state', 'idle') }}
                              '';
                            }
                          ];
                          sequence = writeInstant "nap_utc" "nap_at" "0";
                        }
                      ];
                    }
                    { stop = "Nap housekeeping finished (active alarms are retained)."; }
                  ];
                }
              ];
            }
            {
              choose = [
                {
                  conditions = [
                    {
                      condition = "template";
                      value_template = "{{ not is_state('input_boolean.commute_alarm_enabled', 'on') }}";
                    }
                  ];
                  sequence = [
                    {
                      service = "notify.iphone";
                      data.message = "Alarms disabled — nap not set; enable commute alarms first";
                    }
                    { stop = "Alarms disabled: do not set a nap or enable alarms implicitly."; }
                  ];
                }
              ];
            }
            {
              variables.cap_state = "{{ states('input_text.commute_next_prep_utc') }}";
            }
            {
              choose = [
                {
                  conditions = [
                    {
                      condition = "template";
                      value_template = ''
                        {{ cap_state not in ['unknown', 'unavailable', '${utcSentinel}']
                           and as_timestamp(cap_state, 0) <= as_timestamp(now()) }}
                      '';
                    }
                  ];
                  sequence = [
                    {
                      service = "notify.iphone";
                      data.message = "Nap not set — commute prep cap has passed; refresh the commute plan first";
                    }
                    { stop = "Past prep cap: do not silently remove the hard nap limit."; }
                  ];
                }
              ];
            }
            {
              variables = {
                requested = "{{ as_timestamp(now()) + ([1, minutes | default(30) | int(30)] | max) * 60 }}";
                prep = "{{ as_timestamp(states('input_text.commute_next_prep_utc'), 0) }}";
              };
            }
            {
              variables = {
                capped = "{{ prep | float > as_timestamp(now()) and prep | float < requested | float }}";
                nap = "{{ prep | float if prep | float > as_timestamp(now()) and prep | float < requested | float else requested | float }}";
              };
            }
          ]
          ++ writeInstant "nap_utc" "nap_at" "nap | float"
          ++ [
            {
              service = "notify.iphone";
              data.message = ''
                {% set time = as_local(as_datetime(nap | float)).strftime('%H:%M') %}
                {{ 'Nap capped to ' ~ time ~ ' — ' ~ states('input_text.commute_next_event') ~ ' prep'
                   if capped else 'Nap alarm set for ' ~ time }}
                {% if cap_state in ['unknown', 'unavailable'] %}
                  — prep cap unavailable; commute safety not verified
                {% endif %}
              '';
            }
          ];
        }
        {
          id = "commute_alarm_skip";
          alias = "Commute — skip next alarm";
          mode = "queued";
          sequence = [
            {
              variables.alarm = "{{ states('sensor.commute_next_alarm') }}";
            }
            {
              condition = "template";
              value_template = "{{ as_timestamp(alarm, 0) > as_timestamp(now()) }}";
            }
          ]
          ++ writeInstant "alarm_skipped_utc" "alarm_skipped_at" "as_timestamp(alarm)"
          ++ [
            { service = "script.commute_alarm_fallback_check"; }
            {
              service = "notify.iphone";
              data.message = "{{ 'Skipped commute alarm at ' ~ as_local(as_datetime(alarm)).strftime('%H:%M') }}";
            }
          ];
        }
      ];

      iotHass.nixAutomations = [
        {
          id = "commute_nap_30";
          alias = "Commute — nap button";
          mode = "single";
          trigger = [
            {
              platform = "state";
              entity_id = "input_button.commute_nap_30";
              not_from = [
                "unknown"
                "unavailable"
              ];
            }
          ];
          action = [
            {
              service = "script.commute_nap";
              data.minutes = 30;
            }
          ];
        }
        {
          id = "commute_alarm_offline_fallback";
          alias = "Commute — offline alarm fallback";
          mode = "single";
          # The future-only sensor drops an elapsed alarm at the next minute
          # tick, cancelling a sensor time trigger with a positive offset.
          # Check at +1m, with catch-up only until +3m after a HA restart.
          # Claim even healthy deadlines, so later audio failure cannot revive
          # an already assessed alarm. Off/skip immediately consume deadlines.
          trigger = [
            {
              platform = "time_pattern";
              minutes = "/1";
            }
            {
              platform = "homeassistant";
              event = "start";
            }
            {
              platform = "state";
              entity_id = [
                "input_boolean.commute_alarm_enabled"
                "input_text.commute_alarm_skipped_utc"
                "input_text.commute_wake_utc"
                "input_text.commute_nap_utc"
              ];
            }
          ];
          action = [
            { service = "script.commute_alarm_fallback_check"; }
          ];
        }
        {
          id = "commute_alarm_confirmation_warning";
          alias = "Commute — phone alarm confirmation warning";
          mode = "single";
          trigger = [
            {
              platform = "time";
              at = "23:30:00";
            }
          ];
          condition = [
            {
              condition = "state";
              entity_id = "input_boolean.commute_alarm_enabled";
              state = "on";
            }
            {
              condition = "template";
              value_template = ''
                {{ (as_timestamp(states('input_datetime.commute_alarm_confirmed'), 0) / 60) | int
                   != (as_timestamp(states('input_text.commute_wake_utc'), 0) / 60) | int }}
              '';
            }
          ];
          action = [
            {
              service = "notify.iphone";
              data.message = "⚠️ Phone alarm not set — run the CommuteCompass Shortcut";
            }
          ];
        }
        {
          id = "commute_nap_housekeeping";
          alias = "Commute — clear expired nap";
          mode = "single";
          trigger = [
            {
              platform = "time_pattern";
              minutes = "/1";
            }
          ];
          action = [
            {
              service = "script.commute_nap";
              data.cleanup = true;
            }
          ];
        }
      ];
    };
}

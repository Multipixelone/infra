# Wake-window side effects only. link remains the owner of audio and dismissal;
# sensor.commute_alarm_status is REST-created by link, NEVER declared here.
{
  configurations.nixos.iot.module =
    { pkgs, ... }:
    let
      # Standard YAML InputText is native unknown on a genuinely new install.
      # HA's restore cache distinguishes that from any restored value.
      bootstrap =
        pkgs.runCommand "commute-wake-bootstrap"
          {
            isHomeAssistantComponent = true;
            domain = "commute_wake_bootstrap";
          }
          ''
            mkdir -p $out/custom_components/commute_wake_bootstrap
            cp ${
              pkgs.writeText "commute-wake-bootstrap-manifest.json" (
                builtins.toJSON {
                  domain = "commute_wake_bootstrap";
                  name = "Commute wake ledger bootstrap";
                  version = "1.0.0";
                  dependencies = [ "input_text" ];
                  codeowners = [ ];
                  iot_class = "local_push";
                }
              )
            } $out/custom_components/commute_wake_bootstrap/manifest.json
            cp ${pkgs.writeText "commute-wake-bootstrap.py" ''
              from homeassistant.const import STATE_UNKNOWN
              from homeassistant.helpers import restore_state

              ENTITY = "input_text.commute_alarm_light_owner"

              async def async_setup(hass, config):
                  if hass.config.recovery_mode:
                      return True
                  current = hass.states.get(ENTITY)
                  # Any restore entry, whatever its saved value, is never reset.
                  if (ENTITY not in restore_state.async_get(hass).last_states
                          and current is not None and current.state == STATE_UNKNOWN):
                      await hass.services.async_call(
                          "input_text", "set_value", {"entity_id": ENTITY, "value": "v1:{}"}, blocking=True
                      )
                  return True
            ''} $out/custom_components/commute_wake_bootstrap/__init__.py
          '';

      timing = import ../../lib/commute-alarm.nix;
      ownerEntity = "input_text.commute_alarm_light_owner";
      phoneEntity = "input_text.commute_alarm_phone_claim";
      notifyPhone = "notify.mobile_app_nougat";
      tag = "commute-wake-ring";
      # Every decision AND every phone control re-reads the current observation.
      # Invalid/naive/future timestamps are unknown, not cancellation commands.
      facts = ''
        {% macro epoch(raw) -%}
          {%- set dt = as_datetime(raw, none) if raw is string and raw | regex_search('T.*(Z|[+-][0-9]{2}:[0-9]{2})$') else none -%}
          {{- as_timestamp(dt, -1) if dt is not none and dt.tzinfo is not none else -1 -}}
        {%- endmacro %}
        {% set now_ts = as_timestamp(now()) %}
        {% set obs = epoch(state_attr('sensor.commute_alarm_status', 'observed_at')) | float(-1) %}
        {% set mode = states('sensor.commute_alarm_status') %}
        {% set fresh = state_attr('sensor.commute_alarm_status', 'schema') == 1
           and mode in ['idle', 'ringing', 'snoozed'] and 0 <= now_ts - obs <= ${toString timing.statusMaxAgeSeconds} %}
        {% set s = state_attr('sensor.commute_alarm_status', 'session') %}
        {% set r = state_attr('sensor.commute_alarm_status', 'ring') %}
        {% set session_valid = fresh and s is mapping and s.get('id') is string
           and s.get('id') | regex_match('^[a-f0-9]{32}$')
           and s.get('kind') in ['wake', 'nap'] and s.get('phase') in ['legacy', 'window', 'final']
           and mode in ['ringing', 'snoozed']
           and 0 < epoch(s.get('original_at')) | float(-1) <= obs
           and ((s.phase == 'legacy' and s.get('locked_deadline_at') is none)
                or (s.kind == 'wake' and s.phase in ['window', 'final']
                    and epoch(s.get('locked_deadline_at')) | float(-1) > epoch(s.original_at) | float(-1)
                    and ((s.phase == 'window' and obs < epoch(s.locked_deadline_at) | float(-1))
                         or (s.phase == 'final' and mode == 'ringing' and obs >= epoch(s.locked_deadline_at) | float(-1))))) %}
        {% set window = session_valid and mode in ['ringing', 'snoozed'] and s.kind == 'wake'
           and s.phase in ['window', 'final'] and epoch(s.get('locked_deadline_at')) | float(-1) > 0 %}
        {% set sw = epoch(s.get('original_at')) | float(-1) if session_valid else -1 %}
        {% set sd = epoch(s.get('locked_deadline_at')) | float(-1) if window else -1 %}
        {% set wake = epoch(states('input_text.commute_wake_utc')) | float(-1) %}
        {% set deadline = epoch(states('input_text.commute_alarm_deadline_utc')) | float(-1) %}
        {% set skip = epoch(states('input_text.commute_alarm_skipped_utc')) | float(-1) %}
        {% set done = epoch(states('input_text.commute_alarm_window_done_utc')) | float(-1) %}
        {% set enabled = is_state('input_boolean.commute_alarm_enabled', 'on') %}
        {% set raw = states('${ownerEntity}') %}
        {# Only explicit v1:{} is free; blank/unknown/corrupt fail closed. #}
        {% set o = raw[3:] | from_json(none) if raw.startswith('v1:') else none %}
        {% set record = o is mapping and o.get('p') in ['take', 'held', 'release', 'released']
           and o.get('w', -1) is number and o.get('w', -1) > 0
           and o.get('d', -1) is number and o.get('d', -1) > 0
           and o.get('s') is string and (not o.s or o.s | regex_match('^[a-f0-9]{32}$'))
           and o.get('o') is string and o.get('r') in ['on', 'off']
           and o.get('c', -1) is number and o.get('a', -1) is number %}
        {% set owner_valid = o is mapping and (o | count == 0 or record) %}
        {% set owned = record and o.p in ['take', 'held', 'release'] %}
        {% set bound = owned and window and sw == o.w and (not o.s or s.id == o.s) %}
        {% set ended = state_attr('sensor.commute_alarm_status', 'ended') %}
        {% set e = ended.get('wake') if ended is mapping else none %}
        {% set et = epoch(e.get('ended_at')) | float(-1) if e is mapping else -1 %}
        {% set ew = epoch(e.get('original_at')) | float(-1) if e is mapping else -1 %}
        {% set terminal_valid = fresh and e is mapping and e.get('kind') == 'wake'
           and e.get('session_id') is string and e.get('session_id') | regex_match('^[a-f0-9]{32}$')
           and e.get('phase') in ['window', 'final'] and 0 < ew <= et <= obs
           and epoch(e.get('locked_deadline_at')) | float(-1) > 0
           and e.get('reason') in ['desktop_activity', 'master_off', 'skip', 'schedule_cleared', 'schedule_replaced', 'recovery_expired'] %}
        {% set terminal_match = owned and terminal_valid and ew == o.w
           and (not o.s or e.session_id == o.s)
           and not window %}
        {# The daemon records the dismissal INSTANT, not the delivery time.
           A completion must postdate this acquisition and its previous done
           baseline and belong to this wake's audible interval. Delayed writes
           from an older acquisition cannot end a newer owner's window. Status
           export is advisory and is not required for this safety control. #}
        {% set desktop_done = owned and done > o.c and done >= o.w
           and done >= o.a and done <= now_ts %}
        {# Pinned daemon cancels an active window on WAKE clear, not deadline
           clear: tomorrow may publish a legacy/no-anchor replacement. Before
           session binding a deadline clear does invalidate a pending fade. #}
        {% set safety = owned and (is_state('input_boolean.commute_alarm_enabled', 'off')
           or skip == o.w or wake == 0 or (not o.s and deadline == 0)) %}
        {% set pending = fresh and (s is none or (session_valid and s.kind == 'nap'))
           and enabled and wake > 0 and deadline - wake == ${toString (timing.firstAlarmLeadMinutes * 60)}
           and skip >= 0 and skip != wake
           and not (terminal_valid and ew == wake)
           and done < wake
           and wake - ${toString (timing.lightFadeMinutes * 60)} <= now_ts <= deadline %}
        {% set current_ended = session_valid and e is mapping and e.get('kind') == 'wake'
           and e.get('session_id') == s.id %}
        {# Unlike pending publication, a fresh active session can acquire late,
           including final after restart. Its fade endpoint is already past. #}
        {% set active = window and not current_ended and enabled and wake > 0 and skip >= 0 and skip != sw %}
        {% set target_w = sw if active else wake %}
        {% set target_d = sd if active else deadline %}
        {% set target_s = s.id if active else "" %}
        {% set eligible = (active and done < sw) or pending %}
        {% set ring_started = epoch(r.get('started_at')) | float(-1) if r is mapping else -1 %}
        {% set checked = epoch(r.get('checked_at')) | float(-1) if r is mapping else -1 %}
        {% set ringing = active and not current_ended and done < sw and mode == 'ringing' and r is mapping
           and r.get('id') is string and r.get('id') | regex_match('^[a-f0-9]{32}$')
           and r.get('playback') == 'running' and state_attr('sensor.commute_alarm_status', 'audio_failed') is sameas false
           and 0 < sw <= ring_started <= checked <= obs and 0 <= now_ts - checked <= ${toString timing.statusMaxAgeSeconds}
           and ((s.phase == 'window' and now_ts < sd) or (s.phase == 'final' and now_ts >= sd)) %}
        {% set token = s.id ~ ':' ~ r.id ~ ':' ~ s.phase if ringing else "" %}
        {% set phone_raw = states('${phoneEntity}') %}
        {% set pc = phone_raw[3:] | from_json({}) if phone_raw.startswith('v1:') else {} %}
        {% set pc = pc if pc is mapping else {} %}
      '';
      condition = template: {
        condition = "template";
        value_template = facts + template;
      };
      setOwner = value: {
        service = "input_text.set_value";
        target.entity_id = ownerEntity;
        data.value = facts + "{{ 'v1:' ~ (${value} | to_json) }}";
      };
      setPhone = value: {
        service = "input_text.set_value";
        target.entity_id = phoneEntity;
        data.value = facts + "{{ 'v1:' ~ (${value} | to_json) }}";
      };
      controlValid =
        action:
        facts
        + ''
          {{ ringing and request | default("") == 'CC_${action}:' ~ token
             ${
               if action == "SNOOZE" then
                 "and s.phase == 'window' and now_ts < sd"
               else
                 "and is_state('input_boolean.morning_meds_taken', 'off')"
             } }}
        '';
      # One serial executor owns acquisition, release, claims and phone actions.
      # There are no waits/delays and no second snapshot while a record is owned.
      # WLED service failures abort this run and are retried by the next tick.
    in
    {
      services.home-assistant.customComponents = [ bootstrap ];
      services.home-assistant.config = {
        commute_wake_bootstrap = { };
        input_text = {
          # No initial: do not erase a live restore ledger on HA restart.
          # Bootstrap proves first installation against the restore store.
          # Unknown/corrupt restored records still fail closed.
          commute_alarm_light_owner = {
            name = "Commute — WLED restore ledger";
            max = 255;
          };
          commute_alarm_phone_claim = {
            name = "Commute — wake phone claim";
            max = 255;
          };
          commute_alarm_bedside_claim = {
            name = "Commute — bedside session claim";
            max = 64;
          };
        };
        template = [
          {
            binary_sensor = [
              {
                name = "Commute Alarm Lights Owned";
                unique_id = "commute_alarm_lights_owned";
                # Unknown ownership is not permission for another writer.
                state = facts + "{{ not owner_valid or owned }}";
              }
            ];
          }
        ];
      };

      iotHass.nixScripts = [
        {
          id = "commute_alarm_reconcile";
          alias = "Commute — reconcile wake side effects";
          mode = "queued";
          max = 10;
          max_exceeded = "silent";
          fields.request.description = "Optional session/ring/phase-tokenized companion action.";
          sequence = [
            # A delayed phone event is checked again here, at the service use,
            # not merely by the automation that queued it. Never offer Stop.
            {
              choose = [
                {
                  conditions = [
                    {
                      condition = "template";
                      value_template = controlValid "SNOOZE";
                    }
                  ];
                  sequence = [
                    {
                      condition = "template";
                      value_template = controlValid "SNOOZE";
                    }
                    {
                      service = "input_button.press";
                      target.entity_id = "input_button.commute_alarm_snooze";
                    }
                  ];
                }
                {
                  conditions = [
                    {
                      condition = "template";
                      value_template = controlValid "MEDS";
                    }
                  ];
                  sequence = [
                    {
                      condition = "template";
                      value_template = controlValid "MEDS";
                    }
                    {
                      service = "input_boolean.turn_on";
                      target.entity_id = "input_boolean.morning_meds_taken";
                    }
                  ];
                }
              ];
            }
            {
              choose = [
                {
                  conditions = [
                    (condition "{{ ringing and states('input_text.commute_alarm_bedside_claim') != s.id }}")
                  ];
                  sequence = [
                    # Capture identity, then claim ONLY after successful on.
                    # An idempotent on can retry after failure/interruption.
                    { variables.bedside_session = facts + "{{ s.id }}"; }
                    (condition "{{ ringing and s.id == bedside_session }}")
                    {
                      service = "light.turn_on";
                      target.entity_id = "light.smart_led_bulb";
                    }
                    {
                      service = "input_text.set_value";
                      target.entity_id = "input_text.commute_alarm_bedside_claim";
                      data.value = "{{ bedside_session }}";
                    }
                  ];
                }
              ];
            }
            {
              # A failed clear aborts before v=false; later release still runs
              # and the next reconcile retries the clear.
              continue_on_error = true;
              choose = [
                {
                  conditions = [ (condition "{{ not ringing and pc.get('v', false) }}") ];
                  sequence = [
                    {
                      service = notifyPhone;
                      data = {
                        message = "clear_notification";
                        data.tag = tag;
                      };
                    }
                    (setPhone "dict(k=pc.get('k', ''), v=false)")
                  ];
                }
              ];
            }
            {
              choose = [
                {
                  conditions = [ (condition "{{ ringing and pc.get('k', '') != token }}") ];
                  sequence = [
                    # At most once per session/ring/PHASE, including continuous
                    # final with the same ring ID. Restarts/polls do not resend.
                    (setPhone "dict(k=token, v=true)")
                    (condition "{{ ringing and pc.get('k') == token }}")
                    {
                      service = notifyPhone;
                      continue_on_error = true;
                      data = {
                        title = "Commute alarm";
                        message =
                          facts
                          + "{{ 'Time to leave — dismiss at the desktop' if s.phase == 'final' else 'Wake up — snooze for 5 minutes' }}";
                        data = {
                          inherit tag;
                          push = {
                            sound = "none";
                            "interruption-level" = "passive";
                          };
                          actions = facts + ''
                            {% set buttons = namespace(items=[]) %}
                            {% if s.phase == 'window' and now_ts < sd %}
                              {% set buttons.items = buttons.items + [{'action': 'CC_SNOOZE:' ~ token, 'title': 'Snooze 5 min'}] %}
                            {% endif %}
                            {# Meds remains available in final; only Snooze is window-only. #}
                            {% if is_state('input_boolean.morning_meds_taken', 'off') %}
                              {% set buttons.items = buttons.items + [{'action': 'CC_MEDS:' ~ token, 'title': 'Took meds'}] %}
                            {% endif %}
                            {{ buttons.items }}
                          '';
                        };
                      };
                    }
                  ];
                }
              ];
            } # Commit release intent before restoring either saved value.
            # Independent off/skip/clear works even when status is unknown.
            {
              choose = [
                {
                  conditions = [
                    (condition ''
                      {{ owned and o.p != 'release' and (safety or desktop_done or terminal_match
                         or (window and (sw != o.w or (o.s and s.id != o.s)))
                         or (fresh and not window and not o.s and wake > 0 and deadline > 0
                             and (wake != o.w or deadline != o.d))) }}
                    '')
                  ];
                  sequence = [ (setOwner "dict(o, p='release')") ];
                }
              ];
            }
            {
              choose = [
                {
                  conditions = [ (condition "{{ owned and o.p == 'release' }}") ];
                  sequence = [
                    # NEVER restore the light itself: leave on/color/brightness/
                    # effect exactly as they are. Only relinquish two controls.
                    {
                      service = "select.select_option";
                      target.entity_id = "select.fairy_lights_live_override";
                      data.option = facts + "{{ o.o }}";
                    }
                    {
                      service = facts + "{{ 'switch.turn_on' if o.r == 'on' else 'switch.turn_off' }}";
                      target.entity_id = "switch.fairy_lights_sync_receive";
                    }
                    (setOwner "dict(o, p='released')")
                  ];
                }
              ];
            }
            # Bind a pre-ring snapshot to the first active session. Tomorrow's
            # helper publication cannot replace it; a locked deadline only tightens.
            {
              choose = [
                {
                  conditions = [ (condition "{{ bound and o.p != 'release' and (not o.s or sd < o.d) }}") ];
                  sequence = [ (setOwner "dict(o, s=s.id, d=([o.d, sd] | min))") ];
                }
              ];
            }
            {
              choose = [
                {
                  conditions = [
                    (condition ''
                      {{ owner_valid and not owned and eligible
                         and not (record and (o.w == target_w or (target_s and o.s == target_s)))
                         and states('select.fairy_lights_live_override') not in ['unknown', 'unavailable']
                         and states('select.fairy_lights_live_override') in (state_attr('select.fairy_lights_live_override', 'options') or [])
                         and '2' in (state_attr('select.fairy_lights_live_override', 'options') or [])
                         and states('switch.fairy_lights_sync_receive') in ['on', 'off']
                         and states('light.fairy_lights') in ['on', 'off']
                         and (dict(p='take', w=target_w | int, d=target_d | int, s=target_s,
                              o=states('select.fairy_lights_live_override'), r=states('switch.fairy_lights_sync_receive'),
                              c=done, a=now_ts) | to_json | length) <= 252 }}
                    '')
                  ];
                  sequence = [
                    # Snapshot BOTH controls before takeover; p=take survives
                    # interruption between any of the following service calls.
                    (setOwner "dict(p='take', w=target_w | int, d=target_d | int, s=target_s, o=states('select.fairy_lights_live_override'), r=states('switch.fairy_lights_sync_receive'), c=done, a=now_ts)")
                  ];
                }
              ];
            }
            {
              choose = [
                {
                  conditions = [
                    (condition ''
                      {{ owned and o.p == 'take' and not safety and eligible and target_w == o.w
                         and (not o.s or target_s == o.s) and not terminal_match
                         and states('light.fairy_lights') in ['on', 'off'] }}
                    '')
                  ];
                  sequence = [
                    {
                      service = "select.select_option";
                      target.entity_id = "select.fairy_lights_live_override";
                      data.option = "2";
                    }
                    (condition "{{ owned and o.p == 'take' and not safety and eligible and target_w == o.w and (not o.s or target_s == o.s) }}")
                    {
                      service = "switch.turn_off";
                      target.entity_id = "switch.fairy_lights_sync_receive";
                    }
                    (condition "{{ owned and o.p == 'take' and not safety and eligible and target_w == o.w and (not o.s or target_s == o.s) }}")
                    {
                      service = "light.turn_on";
                      target.entity_id = "light.fairy_lights";
                      data = {
                        brightness = 255;
                        color_temp_kelvin = 2700;
                        effect = "Solid";
                        # Absolute endpoint, not a new ten minutes on retry or
                        # restart. Catch-up after first ring is immediate.
                        transition =
                          facts
                          + "{{ [0, [${toString (timing.lightFadeMinutes * 60)}, o.w - now_ts, o.d - ${
                            toString (timing.firstAlarmLeadMinutes * 60)
                          } - now_ts] | min] | max | int }}";
                      };
                    }
                    (setOwner "dict(o, p='held')")
                  ];
                }
              ];
            }

          ];
        }
      ];

      # Kept separate from commutecompass-alarm.nix's insertion seam: local
      # phone-battery/movement automations there must remain untouched.
      iotHass.nixAutomations = [
        {
          id = "commute_alarm_wake_reconcile";
          alias = "Commute — reconcile wake lights and phone";
          mode = "queued";
          max = 10;
          max_exceeded = "silent";
          trigger = [
            {
              platform = "homeassistant";
              event = "start";
            }
            {
              platform = "time_pattern";
              seconds = "/10";
            }
            {
              platform = "state";
              entity_id = [
                "sensor.commute_alarm_status"
                "input_boolean.commute_alarm_enabled"
                "input_boolean.morning_meds_taken"
                "input_text.commute_wake_utc"
                "input_text.commute_alarm_deadline_utc"
                "input_text.commute_alarm_skipped_utc"
                "input_text.commute_alarm_window_done_utc"
              ];
            }
          ];
          action = [ { service = "script.commute_alarm_reconcile"; } ];
        }
        {
          id = "commute_alarm_phone_action";
          alias = "Commute — validate wake phone action";
          mode = "parallel";
          max = 10;
          trigger = [
            {
              platform = "event";
              event_type = "mobile_app_notification_action";
            }
          ];
          condition = [
            {
              condition = "template";
              value_template = "{{ trigger.event.data.action | default('') is match('^CC_(SNOOZE|MEDS):') }}";
            }
          ];
          action = [
            {
              service = "script.commute_alarm_reconcile";
              data.request = "{{ trigger.event.data.action }}";
            }
          ];
        }
      ];
    };
}

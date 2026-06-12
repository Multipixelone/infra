{
  configurations.nixos.iot.module =
    _:
    let
      morningBool = "input_boolean.morning_meds_taken";
      nightBool = "input_boolean.night_meds_taken";
      notifyFinn = "notify.mobile_app_nougat";
      notifyIphone = "notify.mobile_app_iphone";
    in
    {
      # ── Helpers ──────────────────────────────────────────────────────
      services.home-assistant.config = {
        input_boolean = {
          morning_meds_taken = {
            name = "Morning meds taken";
            icon = "mdi:pill";
          };
          night_meds_taken = {
            name = "Night meds taken";
            icon = "mdi:pill";
          };
        };

        # ── Dashboard visibility sensor ────────────────────────────────────
        # binary_sensor.meds_needed is "on" when at least one med hasn't been
        # taken yet (respecting the 10 PM gate for night meds).  The fridge
        # dashboard's conditional card reads this sensor to decide visibility.
        # Attributes expose the individual flags so the card template doesn't
        # need to duplicate the time-gate logic.
        template = [
          {
            binary_sensor = [
              {
                name = "Meds Needed";
                unique_id = "meds_needed";
                icon = "mdi:pill";
                state = ''
                  {% set morning = is_state('input_boolean.morning_meds_taken', 'off') %}
                  {% set night_pending_attr = is_state('input_boolean.night_meds_taken', 'off') and now().hour >= 22 %}
                  {{ 'on' if (morning or night_pending_attr) else 'off' }}
                '';
                attributes = {
                  morning_pending = ''
                    {{ is_state('input_boolean.morning_meds_taken', 'off') }}
                  '';
                  night_pending = ''
                    {{ is_state('input_boolean.night_meds_taken', 'off') and now().hour >= 22 }}
                  '';
                };
              }
            ];
          }
        ];
      };

      # ── Automations ──────────────────────────────────────────────────
      iotHass.nixAutomations = [
        # 1. Night Meds — Arrival Trigger
        #    When Finn arrives home after 9 PM and night meds haven't been taken.
        {
          alias = "Meds: Night — arrival reminder";
          id = "meds_night_arrival";
          mode = "single";
          triggers = [
            {
              trigger = "state";
              entity_id = "person.finn";
              to = "home";
            }
          ];
          conditions = [
            {
              condition = "time";
              after = "21:00:00";
            }
            {
              condition = "state";
              entity_id = nightBool;
              state = "off";
            }
          ];
          actions = [
            {
              action = notifyFinn;
              data = {
                title = "Night meds";
                message = "You're home and it's past 9 PM — time to take your night meds.";
              };
            }
          ];
        }

        # 2. Night Meds — 11 PM Fallback
        #    If night meds still haven't been taken by 11 PM, remind again.
        {
          alias = "Meds: Night — 11 PM fallback";
          id = "meds_night_fallback";
          mode = "single";
          triggers = [
            {
              trigger = "time";
              at = "23:00:00";
            }
          ];
          conditions = [
            {
              condition = "state";
              entity_id = nightBool;
              state = "off";
            }
          ];
          actions = [
            {
              action = notifyFinn;
              data = {
                title = "Night meds reminder";
                message = "It's 11 PM and you haven't taken your night meds yet.";
              };
            }
          ];
        }

        # 3. Morning Meds — 7:30 AM wake cue
        #    Soft wake-time ping. Fires only if morning meds not yet taken.
        {
          alias = "Meds: Morning — 7:30 AM wake cue";
          id = "meds_morning_wake";
          mode = "single";
          triggers = [
            {
              trigger = "time";
              at = "07:30:00";
            }
          ];
          conditions = [
            {
              condition = "state";
              entity_id = morningBool;
              state = "off";
            }
          ];
          actions = [
            {
              action = notifyFinn;
              data = {
                title = "Good morning";
                message = "Good morning. Water + meds when you're up.";
              };
            }
          ];
        }

        # 3b. Morning Meds — 11:30 AM late-nag
        #     Mid-morning escalation. Distinct, more direct tone.
        {
          alias = "Meds: Morning — 11:30 AM late-nag";
          id = "meds_morning_late_nag";
          mode = "single";
          triggers = [
            {
              trigger = "time";
              at = "11:30:00";
            }
          ];
          conditions = [
            {
              condition = "state";
              entity_id = morningBool;
              state = "off";
            }
          ];
          actions = [
            {
              action = notifyFinn;
              data = {
                title = "Morning meds";
                message = "AM meds still pending — quick reminder.";
              };
            }
          ];
        }

        # 4. Morning Meds — 1 PM Escalation
        #    If morning meds still not taken by 1 PM, notify Finn + iPhone.
        {
          alias = "Meds: Morning — 1 PM escalation";
          id = "meds_morning_escalation";
          mode = "single";
          triggers = [
            {
              trigger = "time";
              at = "13:00:00";
            }
          ];
          conditions = [
            {
              condition = "state";
              entity_id = morningBool;
              state = "off";
            }
          ];
          actions = [
            {
              action = notifyFinn;
              data = {
                title = "Morning meds — overdue!";
                message = "It's 1 PM and you still haven't taken your morning meds.";
              };
            }
            {
              action = notifyIphone;
              data = {
                title = "Finn hasn't taken morning meds";
                message = "It's 1 PM and Finn still hasn't taken his morning meds.";
              };
            }
          ];
        }

        # 5. Daily Reset — 3 AM
        #    Reset both booleans so they're fresh for the new day.
        {
          alias = "Meds: Daily reset";
          id = "meds_daily_reset";
          mode = "single";
          triggers = [
            {
              trigger = "time";
              at = "03:00:00";
            }
          ];
          actions = [
            {
              action = "input_boolean.turn_off";
              target.entity_id = morningBool;
            }
            {
              action = "input_boolean.turn_off";
              target.entity_id = nightBool;
            }
          ];
        }
      ];
    };
}

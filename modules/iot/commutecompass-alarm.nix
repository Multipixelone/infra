# Home Assistant glue for the commutecompass pull-model wake alarm.
#
# `commutecompass tomorrow` (on link) plans tomorrow's events, picks the
# earliest prep_at, and POSTs it to script.commute_set_tomorrow_alarm. The
# script copies that datetime into input_datetime.commute_tomorrow_alarm.
# An iOS Shortcuts daily 21:00 automation polls the helper via the HA REST
# API and creates an on-device Clock-app alarm. No HA-side automation
# beyond this script is required.
#
# Field name is `alarm_at` (not `datetime`) because `datetime` is reserved
# by HA's Jinja namespace — it resolves to the Python module, so a field
# called `datetime` is silently shadowed and `{{ datetime }}` renders as
# the module repr, which `input_datetime.set_datetime` rejects with 400.
{
  configurations.nixos.iot.module = {
    services.home-assistant.config.input_datetime.commute_tomorrow_alarm = {
      name = "Commute — tomorrow alarm";
      has_date = true;
      has_time = true;
      icon = "mdi:alarm";
    };

    iotHass.nixScripts = [
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
    ];
  };
}

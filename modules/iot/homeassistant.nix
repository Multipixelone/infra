{
  lib,
  withSystem,
  ...
}:
{
  # ── HACS (Home Assistant Community Store) ─────────────────────────────
  # HACS version 2.0.5 — pinned at:
  #   https://github.com/hacs/integration/releases/tag/2.0.5
  #
  # Installed as a custom component under custom_components/hacs so that HA
  # discovers it via the service's preStart symlink logic (see module.nix
  # copyCustomComponents).  This is the correct layout for custom integrations.
  #
  # Disable HACS self-update in HA UI after deploy:
  #   HACS → Configuration → uncheck "Check for new versions"
  #   (updates managed via Nix instead).
  # ───────────────────────────────────────────────────────────────────────
  perSystem =
    { pkgs, ... }:
    {
      packages.hacs = pkgs.stdenv.mkDerivation {
        pname = "home-assistant-custom-component-hacs";
        version = "2.0.5";
        src = pkgs.fetchzip {
          url = "https://github.com/hacs/integration/releases/download/2.0.5/hacs.zip";
          hash = "sha256-iMomioxH7Iydy+bzJDbZxt6BX31UkCvqhXrxYFQV8Gw=";
          stripRoot = false;
          postFetch = ''
            # The zip is flat (no top-level directory); create the expected
            # custom_components/hacs layout before installPhase runs.
            mkdir -p $out/custom_components
            mv $out/*/hacs $out/custom_components/ 2>/dev/null || true
            # If the zip was truly flat with no subdir, the files land directly
            # in $out — restructure them here.
            if [ -d "$out/hacs" ]; then
              mv $out/hacs $out/custom_components/
            else
              mkdir -p $out/custom_components/hacs
              mv $out/*.{py,json,yaml,md} $out/custom_components/hacs/ 2>/dev/null || true
              mv $out/*/ $out/custom_components/hacs/ 2>/dev/null || true
            fi
          '';
        };

        # installPhase creates $out/custom_components/hacs — the layout the
        # service preStart uses when symlinking into the HA config dir.
        installPhase = ''
          # The zip is flat — all files land in the unpacked source dir.
          # Move them into the custom_components/hacs layout.
          mkdir -p $out/custom_components/hacs
          cp -r * $out/custom_components/hacs/
        '';

        # Satisfies services.home-assistant.customComponents type check (isHomeAssistantComponent).
        isHomeAssistantComponent = true;

        # Used by the HA module's systemd service to enumerate component domains:
        #   map (getAttr "domain") cfg.customComponents
        # The actual manifest/domain resolution happens inside HA at runtime.
        domain = "hacs";

        meta = with lib; {
          homepage = "https://hacs.xyz/";
          description = "Home Assistant Community Store (HACS)";
          license = licenses.gpl3Only;
          maintainers = with maintainers; [ ludeeus ];
          platforms = platforms.all;
        };
      };
    };

  configurations.nixos.iot.module =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      environment.systemPackages = [
        config.services.home-assistant.finalPackage
      ];

      # HomeKit bridge accessory port. services.home-assistant.openFirewall only
      # opens 8123 (HTTP); the bridge configured via UI listens on 21064 and
      # needs an explicit allow so iOS can reach it to pair.
      networking.firewall.allowedTCPPorts = [ 21064 ];

      services.home-assistant = {
        enable = true;
        openFirewall = true;
        extraComponents = [
          "mobile_app"
          "webhook"
          "default_config"
          "google_translate"
          "hue"
          "bring"
          "matter"
          "mpd"
          "snapcast"
          "apple_tv"
          "icloud"
          "plex"
          "homekit"
          "homekit_controller"
          "todoist"
          "google"
          "wled"
          "opower"
          "mta"
          "govee_ble"
          "govee_light_local"
          "tplink"
          "vesync"
        ];

        # Python runtime dependencies required by integrations that are
        # enabled in extraComponents or config but NOT yet in nixpkgs' HA package.
        extraPackages =
          ps: with ps; [
            gtts
            pyatv
            aiohomekit
            hap-python
            homekit-audio-proxy
            pyqrcode
            base36
            fnv-hash-fast
            pyicloud
            gcal-sync
            oauth2client
            ical
            paho-mqtt
            aionanoleaf2
            led-ble
            hueble
            ibeacon-ble
            xiaomi-ble
          ];

        # ── HACS (Home Assistant Community Store) ─────────────────────────
        # Consumed via withSystem from perSystem.packages.hacs.
        # Mounted at custom_components/hacs by the service preStart symlink.
        # ─────────────────────────────────────────────────────────────────
        customComponents = [
          (withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.hacs))
        ];

        config =
          let
            eufyVacuumEntityId = "vacuum.vaccum";
            eufyWaterLevelSensor = "sensor.vaccum_water_level";
            eufyErrorSensor = "sensor.vaccum_error_message";
            levoitWaterSensor = "binary_sensor.humidifier_low_water";
            todoistLabel = "care";
          in
          {
            # ── Eufy vacuum helpers ──────────────────────────────────────────
            input_boolean = {
              eufy_water_task_open = {
                name = "Eufy water Todoist task open";
                icon = "mdi:water-alert";
                initial = "off";
              };
              levoit_water_task_open = {
                name = "Levoit humidifier water Todoist task open";
                icon = "mdi:water-alert";
                initial = "off";
              };
            };
            # ────────────────────────────────────────────────────────────────

            homeassistant = {
              name = "Home";
              internal_url = "http://192.168.8.111:8123";
              external_url = "https://ha.finnrut.is";
            };

            http = {
              ip_ban_enabled = true;
              login_attempts_threshold = 5;
              use_x_forwarded_for = true;
              trusted_proxies = [
                "127.0.0.1"
                "::1"
              ];
            };

            recorder = {
              auto_purge = true;
              auto_repack = true;
              purge_keep_days = 21;
              commit_interval = 30;
              exclude = {
                domains = [
                  "automation"
                  "script"
                  "update"
                ];
                entities = [
                  "sensor.time"
                  "sensor.date"
                  "sensor.last_boot"
                ];
              };
            };

            automation = lib.filter lib.isAttrs [
              # ── Eufy: low-water Todoist task ────────────────────────────────
              # Uses a dedupe flag so repeated triggers do not spam Todoist.
              {
                alias = "Eufy: Low water — create Todoist task";
                id = "eufy_low_water_task";
                trigger = [
                  {
                    platform = "numeric_state";
                    entity_id = eufyWaterLevelSensor;
                    below = 20;
                  }
                ];
                condition = [
                  {
                    condition = "state";
                    entity_id = "input_boolean.eufy_water_task_open";
                    state = "off";
                  }
                  {
                    condition = "template";
                    value_template = "{{ states('${eufyWaterLevelSensor}') not in ['unavailable', 'unknown', ''] }}";
                  }
                ];
                action = [
                  {
                    service = "todoist.new_task";
                    data = {
                      content = "Refill Eufy vacuum water tank";
                      description = "Refill tank to prevent cleaning interruptions. (Status: Low water warning)";
                      project = "Self";
                      due_date_string = "today";
                      labels = todoistLabel;
                      priority = 2;
                    };
                  }
                  {
                    service = "input_boolean.turn_on";
                    target = {
                      entity_id = "input_boolean.eufy_water_task_open";
                    };
                  }
                ];
              }

              # ── Eufy: error + Todoist task ──────────────────────────────────
              # Fires for low-water error states; dedupe-guarded.
              {
                alias = "Eufy: Error — create Todoist task";
                id = "eufy_error_task";
                trigger = [
                  {
                    platform = "state";
                    entity_id = eufyErrorSensor;
                  }
                ];
                condition = [
                  {
                    condition = "template";
                    value_template = "{{ states('${eufyErrorSensor}') in ['CLEAN WATER LOW', 'STATION LOW CLEAN WATER'] }}";
                  }
                  {
                    condition = "state";
                    entity_id = "input_boolean.eufy_water_task_open";
                    state = "off";
                  }
                ];
                action = [
                  {
                    service = "todoist.new_task";
                    data = {
                      content = "Refill Eufy vacuum water tank";
                      description = "Refill tank and manually resume the vacuum. (Status: Paused with error)";
                      project = "Self";
                      due_date_string = "today";
                      labels = todoistLabel;
                      priority = 2;
                    };
                  }
                  {
                    service = "input_boolean.turn_on";
                    target = {
                      entity_id = "input_boolean.eufy_water_task_open";
                    };
                  }
                ];
              }

              # ── Eufy: water guard — create task if water critically low ─────
              # Creates a Todoist task when water is below 15%.
              {
                alias = "Eufy: Guard — create task if water critically low";
                id = "eufy_water_guard";
                trigger = [
                  {
                    platform = "state";
                    entity_id = eufyVacuumEntityId;
                    to = "cleaning";
                  }
                ];
                condition = [
                  {
                    condition = "numeric_state";
                    entity_id = eufyWaterLevelSensor;
                    below = 15;
                  }
                  {
                    condition = "state";
                    entity_id = "input_boolean.eufy_water_task_open";
                    state = "off";
                  }
                  {
                    condition = "template";
                    value_template = "{{ states('${eufyVacuumEntityId}') not in ['unavailable', 'unknown', ''] }}";
                  }
                ];
                action = [
                  {
                    service = "todoist.new_task";
                    data = {
                      content = "Refill Eufy vacuum water tank";
                      description = "Refill tank before starting the next cycle. (Status: Water critically low)";
                      project = "Self";
                      due_date_string = "today";
                      labels = todoistLabel;
                      priority = 2;
                    };
                  }
                  {
                    service = "input_boolean.turn_on";
                    target = {
                      entity_id = "input_boolean.eufy_water_task_open";
                    };
                  }
                ];
              }

              # ── Eufy: reset dedupe flag when tank is refilled ────────────────
              # Clears the warning flag automatically when water returns to full.
              {
                alias = "Eufy: Water full — reset warning flag";
                id = "eufy_water_full_reset";
                trigger = [
                  {
                    platform = "numeric_state";
                    entity_id = eufyWaterLevelSensor;
                    above = 99;
                  }
                ];
                condition = [
                  {
                    condition = "state";
                    entity_id = "input_boolean.eufy_water_task_open";
                    state = "on";
                  }
                ];
                action = [
                  {
                    service = "input_boolean.turn_off";
                    target = {
                      entity_id = "input_boolean.eufy_water_task_open";
                    };
                  }
                ];
              }

              # ── Levoit: low-water Todoist task ──────────────────────────────
              # Uses a dedupe flag so repeated triggers do not spam Todoist.
              {
                alias = "Levoit: Low water — create Todoist task";
                id = "levoit_low_water_task";
                trigger = [
                  {
                    platform = "state";
                    entity_id = levoitWaterSensor;
                    to = "on";
                  }
                ];
                condition = [
                  {
                    condition = "state";
                    entity_id = "input_boolean.levoit_water_task_open";
                    state = "off";
                  }
                ];
                action = [
                  {
                    service = "todoist.new_task";
                    data = {
                      content = "Refill Levoit humidifier water tank";
                      description = "Remember how nice it is to have nice air?";
                      project = "Self";
                      due_date_string = "today";
                      labels = todoistLabel;
                      priority = 3;
                    };
                  }
                  {
                    service = "input_boolean.turn_on";
                    target = {
                      entity_id = "input_boolean.levoit_water_task_open";
                    };
                  }
                ];
              }

              # ── Levoit: reset dedupe flag when water is restored ───────────
              # Clears the warning flag automatically when low-water state ends.
              {
                alias = "Levoit: Water restored — reset warning flag";
                id = "levoit_water_restored_reset";
                trigger = [
                  {
                    platform = "state";
                    entity_id = levoitWaterSensor;
                    to = "off";
                  }
                ];
                condition = [
                  {
                    condition = "state";
                    entity_id = "input_boolean.levoit_water_task_open";
                    state = "on";
                  }
                ];
                action = [
                  {
                    service = "input_boolean.turn_off";
                    target = {
                      entity_id = "input_boolean.levoit_water_task_open";
                    };
                  }
                ];
              }

              # ── Phone: low-battery calendar reminder ───────────────────────────
              # Notifies 3 hours before a calendar event starts if battery is
              # below 30% and the phone is not already charging.
              {
                alias = "Phone: Low battery — calendar charge reminder";
                id = "phone_low_battery_calendar_reminder";
                trigger = [
                  {
                    platform = "calendar";
                    entity_id = "calendar.finn";
                    offset = "-03:00:00";
                    event = "start";
                  }
                ];
                condition = [
                  {
                    condition = "numeric_state";
                    entity_id = "sensor.nougat_battery_level";
                    below = 30;
                  }
                  {
                    condition = "not";
                    conditions = [
                      {
                        condition = "state";
                        entity_id = "sensor.nougat_battery_state";
                        state = "Charging";
                      }
                    ];
                  }
                ];
                action = [
                  {
                    service = "notify.mobile_app_nougat";
                    data = {
                      message = "Charge phone for {{ trigger.event.summary }} (battery at {{ states('sensor.nougat_battery_level') }}%)";
                      title = "Charge phone before event";
                    };
                  }
                ];
              }

              # ── Foodtown: keep shopping list sorted ─────────────────────────
              # Fires on arrival at Foodtown, and on item additions while
              # already there (state-change trigger with 30 s `for` debounces
              # bursts of additions and ignores reductions via the template
              # condition). shell_command asks OpenAI to reorder the list in
              # Bedstuy walking order and rewrites each item with a prefix.
              {
                alias = "Foodtown: sort shopping list";
                id = "foodtown_sort_shopping_list";
                mode = "single";
                trigger = [
                  {
                    platform = "zone";
                    id = "arrival";
                    entity_id = "person.finn";
                    zone = "zone.foodtown";
                    event = "enter";
                  }
                  {
                    platform = "state";
                    id = "list_grew";
                    entity_id = "todo.foodtown";
                    for = {
                      seconds = 30;
                    };
                  }
                ];
                condition = [
                  {
                    condition = "template";
                    value_template = ''
                      {{ trigger.id == 'arrival'
                         or (is_state('person.finn', 'Foodtown')
                             and trigger.from_state is not none
                             and (trigger.to_state.state | int(0)) > (trigger.from_state.state | int(0))) }}
                    '';
                  }
                ];
                action = [
                  {
                    service = "shell_command.sort_foodtown";
                  }
                ];
              }

              # Existing: Nightly Home Assistant backup
              {
                alias = "Nightly Home Assistant Backup";
                trigger = [
                  {
                    platform = "time";
                    at = "03:00:00";
                  }
                ];
                action = [
                  {
                    service = "backup.create";
                  }
                ];
              }
            ];

            mobile_app = { };
          };
      };
    };
}

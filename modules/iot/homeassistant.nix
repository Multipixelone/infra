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
    let
      # ── Host-id constants (lifted from inner let) ───────────────────────
      eufyVacuumEntityId = "vacuum.vaccum";
      eufyWaterLevelSensor = "sensor.vaccum_water_level";
      eufyErrorSensor = "sensor.vaccum_error_message";
      levoitWaterSensor = "binary_sensor.humidifier_low_water";
      todoistLabel = "care";

      # ── YAML generation ─────────────────────────────────────────────────
      yamlFormat = pkgs.formats.yaml { };

      # Mirror nixpkgs HA module's customLovelaceModules → lovelace.resources merge
      customLovelaceModulesResources = {
        lovelace.resources = map (card: {
          url = "/local/nixos-lovelace-modules/${card.entrypoint or (card.pname + ".js")}";
          type = "module";
        }) config.services.home-assistant.customLovelaceModules;
      };

      mergedConfig = lib.recursiveUpdate (lib.optionalAttrs (
        config.services.home-assistant.customLovelaceModules != [ ]
      ) customLovelaceModulesResources) config.services.home-assistant.config;

      # Fixed-point null pruning (matches upstream HA module)
      filterConfig = lib.converge (lib.filterAttrsRecursive (_n: v: v != null));

      baseConfigYaml = yamlFormat.generate "configuration-base.yaml" (filterConfig mergedConfig);
      automationsNixYaml = yamlFormat.generate "automations_nix.yaml" config.iotHass.nixAutomations;

      finalConfigYaml = pkgs.runCommand "configuration.yaml" { } ''
        cp ${baseConfigYaml} $out
        chmod +w $out
        # Mirror upstream: un-quote YAML tag strings like '!secret foo' → !secret foo
        sed -i -e "s/'\!\([a-z_]\+\) \(.*\)'/\!\1 \2/;s/^\!\!/\!/;" $out
        cat >> $out <<'EOF'

        # ── Automations ──
        automation manual: !include /etc/home-assistant/automations_nix.yaml
        automation ui: !include automations.yaml
        EOF
      '';
    in
    {
      options.iotHass.nixAutomations = lib.mkOption {
        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
        default = [ ];
        description = ''
          Home Assistant automations declared via Nix. Aggregated and serialized
          into /etc/home-assistant/automations_nix.yaml, loaded by HA via
          `automation manual: !include`. Coexists with the UI-managed
          /var/lib/hass/automations.yaml (loaded via `automation ui: !include`).
        '';
      };

      config = {
        environment.systemPackages = [
          config.services.home-assistant.finalPackage
        ];

        # HomeKit bridge accessory port. services.home-assistant.openFirewall only
        # opens 8123 (HTTP); the bridge configured via UI listens on 21064 and
        # needs an explicit allow so iOS can reach it to pair.
        networking.firewall.allowedTCPPorts = [ 21064 ];

        # ── Nix-managed automations ────────────────────────────────────────
        # Moved out of services.home-assistant.config so HA merges both Nix and UI
        # automations via `automation manual:` / `automation ui:` !include directives.
        iotHass.nixAutomations = [
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

          # ── Sunset bedroom fade ─────────────────────────────────────────
          # 30 min before sunset, fade Bedside Lamp -> Blue and Corner Lamp
          # -> Red, both at 10% brightness, over a 15 minute transition.
          {
            alias = "Sunset bedroom fade";
            id = "sunset_bedroom_fade";
            mode = "single";
            trigger = [
              {
                platform = "sun";
                event = "sunset";
                offset = "-00:30:00";
              }
            ];
            action = [
              {
                service = "light.turn_on";
                target = {
                  entity_id = "light.smart_led_bulb";
                };
                data = {
                  rgb_color = [
                    0
                    0
                    255
                  ];
                  brightness_pct = 10;
                  transition = 900;
                };
              }
              {
                service = "light.turn_on";
                target = {
                  entity_id = "light.smart_led_bulb_2";
                };
                data = {
                  rgb_color = [
                    255
                    0
                    0
                  ];
                  brightness_pct = 10;
                  transition = 900;
                };
              }
              {
                service = "select.select_option";
                target = {
                  entity_id = "select.fairy_lights_preset";
                };
                data = {
                  option = "Twinkle Stars";
                };
              }
            ];
          }

          # ── Living Room: media lighting ─────────────────────────────────
          # Turn off corner lamp when Apple TV plays; dim Hue at night.
          # Restore lights when playback stops.
          {
            alias = "Living Room media lighting";
            id = "living_room_media_lighting";
            mode = "queued";
            max = 2;
            trigger = [
              {
                platform = "state";
                entity_id = "media_player.living_room";
                id = "playing";
                to = "playing";
                for = {
                  seconds = 1;
                };
              }
              {
                platform = "state";
                entity_id = "media_player.living_room";
                id = "not_playing";
                from = "playing";
                to = [
                  "paused"
                  "idle"
                  "standby"
                  "off"
                ];
                for = {
                  seconds = 5;
                };
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.living_room_appletv_dim_enabled";
                state = "on";
              }
            ];
            action = [
              {
                choose = [
                  {
                    conditions = [
                      {
                        condition = "trigger";
                        id = "playing";
                      }
                      {
                        condition = "state";
                        entity_id = "input_boolean.living_room_appletv_dim_active";
                        state = "off";
                      }
                    ];
                    sequence = [
                      # Brief delay so Apple TV populates app_id/media_content_type
                      # attributes before we branch on them.
                      { delay = "00:00:01"; }
                      # Snapshot pre-playback state of lights currently on so
                      # restore can return them to their actual previous values
                      # (lights that were off stay off).
                      {
                        service = "scene.create";
                        data = {
                          scene_id = "living_room_pre_appletv";
                          snapshot_entities = "{{ ['light.living_room', 'light.smart_led_bulb_2'] | select('is_state', 'on') | list }}";
                        };
                      }
                      {
                        service = "input_boolean.turn_on";
                        target = {
                          entity_id = "input_boolean.living_room_appletv_dim_active";
                        };
                      }
                      # ── Content-based branching ──────────────────────────
                      # YouTube → dim only the corner lamp (Hue untouched).
                      # Otherwise → off corner lamp + dim Hue (or off Hue at night).
                      {
                        choose = [
                          {
                            conditions = [
                              {
                                condition = "template";
                                value_template = "{{ 'youtube' in (state_attr('media_player.living_room', 'app_id') | default('') | lower) }}";
                              }
                            ];
                            sequence = [
                              {
                                service = "light.turn_on";
                                target = {
                                  entity_id = "light.smart_led_bulb_2";
                                };
                                data = {
                                  brightness_pct = 15;
                                  transition = 2;
                                };
                              }
                            ];
                          }
                        ];
                        default = [
                          {
                            service = "light.turn_off";
                            target = {
                              entity_id = "light.smart_led_bulb_2";
                            };
                            data = {
                              transition = 2;
                            };
                          }
                          {
                            choose = [
                              {
                                conditions = [
                                  {
                                    condition = "sun";
                                    after = "sunset";
                                    after_offset = "-00:30:00";
                                  }
                                ];
                                sequence = [
                                  {
                                    service = "light.turn_on";
                                    target = {
                                      entity_id = "light.living_room";
                                    };
                                    data = {
                                      brightness_pct = 10;
                                      transition = 2;
                                    };
                                  }
                                ];
                              }
                            ];
                            default = [
                              {
                                service = "light.turn_on";
                                target = {
                                  entity_id = "light.living_room";
                                };
                                data = {
                                  brightness_pct = 50;
                                  transition = 2;
                                };
                              }
                            ];
                          }
                        ];
                      }
                    ];
                  }
                  {
                    conditions = [
                      {
                        condition = "trigger";
                        id = "not_playing";
                      }
                      {
                        condition = "state";
                        entity_id = "input_boolean.living_room_appletv_dim_active";
                        state = "on";
                      }
                    ];
                    sequence = [
                      {
                        service = "scene.turn_on";
                        target = {
                          entity_id = "scene.living_room_pre_appletv";
                        };
                        data = {
                          transition = 2;
                        };
                      }
                      {
                        service = "input_boolean.turn_off";
                        target = {
                          entity_id = "input_boolean.living_room_appletv_dim_active";
                        };
                      }
                    ];
                  }
                ];
              }
            ];
          }

          # ── Vacuum: auto-run when both Finn & Ciara have been away 1h ──
          # Fires `vacuum.start` when both persons have been `not_home` for
          # at least 1h, gated by: time-of-day window, docked + battery
          # preconditions, once-per-day cooldown, and a manual skip toggle.
          # NOTE: the `for:` timer resets on HA restart (state-trigger
          # behaviour); accepted trade-off vs an input_datetime-tracked clock.
          {
            alias = "Vacuum: Auto-run when both away ≥ 1h";
            id = "vacuum_auto_when_both_away";
            mode = "single";
            trigger = [
              {
                platform = "state";
                entity_id = "person.finn";
                to = "not_home";
                for = {
                  hours = 1;
                };
              }
              {
                platform = "state";
                entity_id = "person.ciara";
                to = "not_home";
                for = {
                  hours = 1;
                };
              }
            ];
            condition = [
              # Both persons currently away.
              {
                condition = "state";
                entity_id = "person.finn";
                state = "not_home";
              }
              {
                condition = "state";
                entity_id = "person.ciara";
                state = "not_home";
              }
              # Daytime window — never start at 3am.
              {
                condition = "time";
                after = "09:00:00";
                before = "21:00:00";
              }
              # Manual skip toggle.
              {
                condition = "state";
                entity_id = "input_boolean.vacuum_auto_skip_today";
                state = "off";
              }
              # Vacuum must be docked (not cleaning / returning / errored).
              {
                condition = "state";
                entity_id = eufyVacuumEntityId;
                state = "docked";
              }
              # Battery healthy enough to finish a run.
              {
                condition = "numeric_state";
                entity_id = "sensor.vaccum_battery";
                above = 30;
              }
              # Cooldown: ≥ 12h since last auto-run.
              {
                condition = "template";
                value_template = ''
                  {% set last = states('input_datetime.vacuum_last_auto_run') %}
                  {{ last in ['unknown', 'unavailable', '''] or
                     (as_timestamp(now()) - as_timestamp(last)) > 12 * 3600 }}
                '';
              }
            ];
            action = [
              {
                service = "input_datetime.set_datetime";
                target = {
                  entity_id = "input_datetime.vacuum_last_auto_run";
                };
                data = {
                  datetime = "{{ now().strftime('%Y-%m-%d %H:%M:%S') }}";
                };
              }
              {
                service = "vacuum.start";
                target = {
                  entity_id = eufyVacuumEntityId;
                };
              }
              {
                service = "notify.notify";
                data = {
                  title = "Vacuum started";
                  message = "House empty ≥ 1h — starting auto clean.";
                };
              }
            ];
          }

          # ── Vacuum: reset "skip today" toggle nightly ───────────────────
          {
            alias = "Vacuum: Reset skip-today toggle at midnight";
            id = "vacuum_auto_skip_reset";
            trigger = [
              {
                platform = "time";
                at = "00:01:00";
              }
            ];
            action = [
              {
                service = "input_boolean.turn_off";
                target = {
                  entity_id = "input_boolean.vacuum_auto_skip_today";
                };
              }
            ];
          }

          # ── Living Room: clear stale dim flag on HA restart ────────────
          # Safety net: if HA restarts mid-playback, the dim flag could be
          # stuck "on" preventing lights from restoring.
          {
            alias = "Clear stale Apple TV dim flag on HA start";
            id = "living_room_appletv_dim_startup_reset";
            trigger = [
              {
                platform = "homeassistant";
                event = "start";
              }
            ];
            action = [
              {
                service = "input_boolean.turn_off";
                target = {
                  entity_id = "input_boolean.living_room_appletv_dim_active";
                };
              }
            ];
          }
        ];

        services.home-assistant = {
          enable = true;
          openFirewall = true;
          extraComponents = [
            "mobile_app"
            "webhook"
            "default_config"
            "google_translate"
            "hue"
            "steam_online"
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
              # Faster zlib for aiohttp_fast_zlib (silences "performance will be degraded" warning).
              isal
              zlib-ng
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

          config = {
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
              living_room_appletv_dim_enabled = {
                name = "Enable Apple TV light automation";
                initial = "on";
              };
              living_room_appletv_dim_active = {
                name = "Apple TV lights currently adjusted";
                initial = "off";
              };
              vacuum_auto_skip_today = {
                name = "Skip automatic vacuum today";
                icon = "mdi:robot-vacuum-off";
                initial = "off";
              };
            };
            input_datetime = {
              vacuum_last_auto_run = {
                name = "Vacuum last auto-run";
                has_date = true;
                has_time = true;
                # Seed far enough in the past that the first run isn't gated.
                initial = "2020-01-01 00:00:00";
              };
            };
            # ────────────────────────────────────────────────────────────────

            homeassistant = {
              name = "Home";
              internal_url = "http://192.168.8.111:8123";
              external_url = "https://ha.finnrut.is";
              # ── Auth providers ─────────────────────────────────────────────────
              # When `auth_providers` is set, HA stops auto-adding defaults, so we
              # re-include `homeassistant` (password login) explicitly alongside
              # `trusted_networks` so regular browsers still work.
              #
              # MANUAL SETUP (one-time) — required for trusted_networks to auto-login:
              #  1. In HA UI → Settings → People → Add Person, create a non-admin
              #     user e.g. "kiosk".  Set a strong password (you'll never type it).
              #  2. SSH to iot and get the kiosk user UUID:
              #     sudo cat /var/lib/home-assistant/.storage/auth \
              #       | jq -r '.data.users[] | select(.name=="kiosk") | .id'
              #  3. Replace REPLACE_WITH_KIOSK_USER_UUID below with that UUID.
              #  4. Restart the vnc-ipad container; it should bypass login.
              # ──────────────────────────────────────────────────────────────────
              auth_providers = [
                { type = "homeassistant"; }
                {
                  type = "trusted_networks";
                  trusted_networks = [ "10.88.0.0/16" ]; # podman bridge — iot only
                  trusted_users = {
                    "10.88.0.0/16" = "57d8c16f5c984f9e8b62fd2626086028";
                  };
                  allow_bypass_login = true;
                }
              ];
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

            # NOTE: automation key is NO LONGER set here.
            # Nix-managed automations live in iotHass.nixAutomations (output to
            # /etc/home-assistant/automations_nix.yaml, loaded via
            # `automation manual: !include`). UI-managed automations live in
            # /var/lib/hass/automations.yaml (loaded via `automation ui: !include`).

            mobile_app = { };
          };
        };

        # ── HA config files (YAML generation) ─────────────────────────────
        # Generated configuration.yaml bypasses the typed module and appends
        # !include directives so HA loads both Nix-declared and UI-declared
        # automations. automations_nix.yaml is the serialized Nix automation list.
        environment.etc."home-assistant/automations_nix.yaml".source = automationsNixYaml;
        environment.etc."home-assistant/configuration.yaml".source = lib.mkForce finalConfigYaml;

        # Ensure systemd picks up changes to generated files on reload/restart
        systemd.services.home-assistant.reloadTriggers = lib.mkAfter [
          automationsNixYaml
          finalConfigYaml
        ];

        # Ensure the UI-managed automations file exists on first boot so the
        # `!include automations.yaml` directive doesn't fail.
        systemd.services.home-assistant.preStart = lib.mkAfter ''
          if [ ! -e "${config.services.home-assistant.configDir}/automations.yaml" ]; then
            touch "${config.services.home-assistant.configDir}/automations.yaml"
          fi
        '';
      };
    };
}

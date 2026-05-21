{
  inputs,
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
          hash = "sha256-ZVJhH0SC9DeVFE6eEv3g6ZQyyOpY+UMG18DvCnukrh8=";
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

        # Shared agenix secrets for HA-adjacent shell_command scripts
        # (foodtown-sort.nix, nudge-writer.nix). Declared once here so multiple
        # consumers can reference config.age.secrets.<name>.path without
        # conflicting double-declarations.
        age.secrets = {
          "homeassistant-token" = {
            file = "${inputs.secrets}/iot/homeassistant-token.age";
            owner = "hass";
            group = "hass";
            mode = "0400";
          };
          "openai" = {
            file = "${inputs.secrets}/ai/openai.age";
            owner = "hass";
            group = "hass";
            mode = "0400";
          };
        };

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
                  project = "Chores";
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
                  project = "Chores";
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
                  project = "Chores";
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

          # ── Eufy: consumable wear-life → Todoist tasks ──────────────────
          # Mirrors the Eufy low-water pattern: each consumable has a
          # warning automation (fires at ~10% of lifespan) and a reset
          # automation (fires when the value jumps back above ~90% after
          # the user presses the corresponding reset button in HA).
          {
            alias = "Eufy: Filter low — create Todoist task";
            id = "eufy_filter_low_task";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.vaccum_filter_remaining";
                below = 36;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.vacuum_filter_task_open";
                state = "off";
              }
              {
                condition = "template";
                value_template = "{{ states('sensor.vaccum_filter_remaining') not in ['unavailable', 'unknown', ''] }}";
              }
            ];
            action = [
              {
                service = "todoist.new_task";
                data = {
                  content = "Replace Eufy vacuum HEPA filter";
                  description = "Filter has {{ states('sensor.vaccum_filter_remaining') }}h life remaining (360h total). Press the Reset Filter button in HA after installing the new one.";
                  project = "Chores";
                  due_date_string = "today";
                  labels = todoistLabel;
                  priority = 3;
                };
              }
              {
                service = "input_boolean.turn_on";
                target = {
                  entity_id = "input_boolean.vacuum_filter_task_open";
                };
              }
            ];
          }

          {
            alias = "Eufy: Filter renewed — reset warning flag";
            id = "eufy_filter_renewed_reset";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.vaccum_filter_remaining";
                above = 324;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.vacuum_filter_task_open";
                state = "on";
              }
            ];
            action = [
              {
                service = "input_boolean.turn_off";
                target = {
                  entity_id = "input_boolean.vacuum_filter_task_open";
                };
              }
            ];
          }

          {
            alias = "Eufy: Rolling brush low — create Todoist task";
            id = "eufy_rolling_brush_low_task";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.vaccum_rolling_brush_remaining";
                below = 36;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.vacuum_rolling_brush_task_open";
                state = "off";
              }
              {
                condition = "template";
                value_template = "{{ states('sensor.vaccum_rolling_brush_remaining') not in ['unavailable', 'unknown', ''] }}";
              }
            ];
            action = [
              {
                service = "todoist.new_task";
                data = {
                  content = "Replace Eufy vacuum rolling brush";
                  description = "Rolling brush has {{ states('sensor.vaccum_rolling_brush_remaining') }}h life remaining (360h total). Press the Reset Rolling Brush button in HA after installing the new one.";
                  project = "Chores";
                  due_date_string = "today";
                  labels = todoistLabel;
                  priority = 3;
                };
              }
              {
                service = "input_boolean.turn_on";
                target = {
                  entity_id = "input_boolean.vacuum_rolling_brush_task_open";
                };
              }
            ];
          }

          {
            alias = "Eufy: Rolling brush renewed — reset warning flag";
            id = "eufy_rolling_brush_renewed_reset";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.vaccum_rolling_brush_remaining";
                above = 324;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.vacuum_rolling_brush_task_open";
                state = "on";
              }
            ];
            action = [
              {
                service = "input_boolean.turn_off";
                target = {
                  entity_id = "input_boolean.vacuum_rolling_brush_task_open";
                };
              }
            ];
          }

          {
            alias = "Eufy: Side brush low — create Todoist task";
            id = "eufy_side_brush_low_task";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.vaccum_side_brush_remaining";
                below = 18;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.vacuum_side_brush_task_open";
                state = "off";
              }
              {
                condition = "template";
                value_template = "{{ states('sensor.vaccum_side_brush_remaining') not in ['unavailable', 'unknown', ''] }}";
              }
            ];
            action = [
              {
                service = "todoist.new_task";
                data = {
                  content = "Replace Eufy vacuum side brush";
                  description = "Side brush has {{ states('sensor.vaccum_side_brush_remaining') }}h life remaining (180h total). Press the Reset Side Brush button in HA after installing the new one.";
                  project = "Chores";
                  due_date_string = "today";
                  labels = todoistLabel;
                  priority = 3;
                };
              }
              {
                service = "input_boolean.turn_on";
                target = {
                  entity_id = "input_boolean.vacuum_side_brush_task_open";
                };
              }
            ];
          }

          {
            alias = "Eufy: Side brush renewed — reset warning flag";
            id = "eufy_side_brush_renewed_reset";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.vaccum_side_brush_remaining";
                above = 162;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.vacuum_side_brush_task_open";
                state = "on";
              }
            ];
            action = [
              {
                service = "input_boolean.turn_off";
                target = {
                  entity_id = "input_boolean.vacuum_side_brush_task_open";
                };
              }
            ];
          }

          {
            alias = "Eufy: Nav sensors due for cleaning — create Todoist task";
            id = "eufy_sensors_low_task";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.vaccum_sensor_remaining";
                below = 6;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.vacuum_sensors_task_open";
                state = "off";
              }
              {
                condition = "template";
                value_template = "{{ states('sensor.vaccum_sensor_remaining') not in ['unavailable', 'unknown', ''] }}";
              }
            ];
            action = [
              {
                service = "todoist.new_task";
                data = {
                  content = "Clean Eufy vacuum nav sensors";
                  description = "Wipe IR/cliff sensors with a dry microfibre cloth. {{ states('sensor.vaccum_sensor_remaining') }}h life remaining (60h total). Press the Reset Sensors button in HA when done.";
                  project = "Chores";
                  due_date_string = "today";
                  labels = todoistLabel;
                  priority = 3;
                };
              }
              {
                service = "input_boolean.turn_on";
                target = {
                  entity_id = "input_boolean.vacuum_sensors_task_open";
                };
              }
            ];
          }

          {
            alias = "Eufy: Nav sensors cleaned — reset warning flag";
            id = "eufy_sensors_cleaned_reset";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.vaccum_sensor_remaining";
                above = 54;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.vacuum_sensors_task_open";
                state = "on";
              }
            ];
            action = [
              {
                service = "input_boolean.turn_off";
                target = {
                  entity_id = "input_boolean.vacuum_sensors_task_open";
                };
              }
            ];
          }

          {
            alias = "Eufy: Cleaning tray due for service — create Todoist task";
            id = "eufy_cleaning_tray_low_task";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.vaccum_cleaning_tray_remaining";
                below = 3;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.vacuum_cleaning_tray_task_open";
                state = "off";
              }
              {
                condition = "template";
                value_template = "{{ states('sensor.vaccum_cleaning_tray_remaining') not in ['unavailable', 'unknown', ''] }}";
              }
            ];
            action = [
              {
                service = "todoist.new_task";
                data = {
                  content = "Clean Eufy vacuum cleaning tray";
                  description = "Rinse the mopping tray and clear any debris. {{ states('sensor.vaccum_cleaning_tray_remaining') }}h life remaining (30h total). Press the Reset Cleaning Tray button in HA when done.";
                  project = "Chores";
                  due_date_string = "today";
                  labels = todoistLabel;
                  priority = 3;
                };
              }
              {
                service = "input_boolean.turn_on";
                target = {
                  entity_id = "input_boolean.vacuum_cleaning_tray_task_open";
                };
              }
            ];
          }

          {
            alias = "Eufy: Cleaning tray serviced — reset warning flag";
            id = "eufy_cleaning_tray_serviced_reset";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.vaccum_cleaning_tray_remaining";
                above = 27;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.vacuum_cleaning_tray_task_open";
                state = "on";
              }
            ];
            action = [
              {
                service = "input_boolean.turn_off";
                target = {
                  entity_id = "input_boolean.vacuum_cleaning_tray_task_open";
                };
              }
            ];
          }

          {
            alias = "Eufy: Mop cloth low — create Todoist task";
            id = "eufy_mopping_cloth_low_task";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.vaccum_mopping_cloth_remaining";
                below = 18;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.vacuum_mopping_cloth_task_open";
                state = "off";
              }
              {
                condition = "template";
                value_template = "{{ states('sensor.vaccum_mopping_cloth_remaining') not in ['unavailable', 'unknown', ''] }}";
              }
            ];
            action = [
              {
                service = "todoist.new_task";
                data = {
                  content = "Wash Eufy mopping cloth (or replace if worn)";
                  description = "Mopping cloth has {{ states('sensor.vaccum_mopping_cloth_remaining') }}h life remaining (180h total). Press the Reset Mopping Cloth button in HA after replacing.";
                  project = "Chores";
                  due_date_string = "today";
                  labels = todoistLabel;
                  priority = 3;
                };
              }
              {
                service = "input_boolean.turn_on";
                target = {
                  entity_id = "input_boolean.vacuum_mopping_cloth_task_open";
                };
              }
            ];
          }

          {
            alias = "Eufy: Mop cloth renewed — reset warning flag";
            id = "eufy_mopping_cloth_renewed_reset";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.vaccum_mopping_cloth_remaining";
                above = 162;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.vacuum_mopping_cloth_task_open";
                state = "on";
              }
            ];
            action = [
              {
                service = "input_boolean.turn_off";
                target = {
                  entity_id = "input_boolean.vacuum_mopping_cloth_task_open";
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
                  project = "Chores";
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

          # ── Levoit: filter sponges → Todoist order task ─────────────────
          # No reset button on the integration — sensor jumps back to ~100
          # automatically when a new filter is installed and the device
          # registers it.
          {
            alias = "Levoit: Filter sponges low — create Todoist task";
            id = "levoit_filter_low_task";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.humidifier_filter_lifetime";
                below = 15;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.levoit_filter_task_open";
                state = "off";
              }
              {
                condition = "template";
                value_template = "{{ states('sensor.humidifier_filter_lifetime') not in ['unavailable', 'unknown', ''] }}";
              }
            ];
            action = [
              {
                service = "todoist.new_task";
                data = {
                  content = "Order new Levoit humidifier filter sponges";
                  description = "Filter at {{ states('sensor.humidifier_filter_lifetime') }}% — Levoit replacement sponges typically last ~3 months.";
                  project = "Chores";
                  due_date_string = "today";
                  labels = todoistLabel;
                  priority = 3;
                };
              }
              {
                service = "input_boolean.turn_on";
                target = {
                  entity_id = "input_boolean.levoit_filter_task_open";
                };
              }
            ];
          }

          {
            alias = "Levoit: Filter sponges renewed — reset warning flag";
            id = "levoit_filter_renewed_reset";
            trigger = [
              {
                platform = "numeric_state";
                entity_id = "sensor.humidifier_filter_lifetime";
                above = 95;
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.levoit_filter_task_open";
                state = "on";
              }
            ];
            action = [
              {
                service = "input_boolean.turn_off";
                target = {
                  entity_id = "input_boolean.levoit_filter_task_open";
                };
              }
            ];
          }

          # ── Consumables: press hardware reset when Todoist task is completed ──
          # Water + Levoit-filter sensors recover on their own (real-time level
          # or device-side detection), so they are not synced here. The Eufy
          # consumables below only reset when the corresponding HA button is
          # pressed; doing it here lets checking the Todoist task off also
          # reset the on-device wear-life counter. The existing
          # `*_renewed_reset` automations then clear the dedupe flag once the
          # sensor jumps back to ~100%.
          {
            alias = "Consumables: Sync flags from Todoist completion";
            id = "consumable_flag_sync_from_todoist";
            mode = "single";
            trigger = [
              {
                platform = "state";
                entity_id = "todo.chores";
              }
              {
                platform = "time_pattern";
                minutes = "/30";
              }
            ];
            action = [
              {
                service = "todo.get_items";
                target = {
                  entity_id = "todo.chores";
                };
                data = {
                  status = "needs_action";
                };
                response_variable = "chores";
              }
              {
                repeat = {
                  for_each = [
                    {
                      flag = "vacuum_filter_task_open";
                      summary = "Replace Eufy vacuum HEPA filter";
                      reset_button = "button.vaccum_reset_filter";
                    }
                    {
                      flag = "vacuum_rolling_brush_task_open";
                      summary = "Replace Eufy vacuum rolling brush";
                      reset_button = "button.vaccum_reset_rolling_brush";
                    }
                    {
                      flag = "vacuum_side_brush_task_open";
                      summary = "Replace Eufy vacuum side brush";
                      reset_button = "button.vaccum_reset_side_brush";
                    }
                    {
                      flag = "vacuum_sensors_task_open";
                      summary = "Clean Eufy vacuum nav sensors";
                      reset_button = "button.vaccum_reset_sensors";
                    }
                    {
                      flag = "vacuum_cleaning_tray_task_open";
                      summary = "Clean Eufy vacuum cleaning tray";
                      reset_button = "button.vaccum_reset_cleaning_tray";
                    }
                    {
                      flag = "vacuum_mopping_cloth_task_open";
                      summary = "Wash Eufy mopping cloth (or replace if worn)";
                      reset_button = "button.vaccum_reset_mopping_cloth";
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
                                {% set items = (chores | default({})).get('todo.chores', {}).get('items', []) %}
                                {% set summaries = items | map(attribute='summary') | list %}
                                {{ is_state('input_boolean.' ~ repeat.item.flag, 'on') and repeat.item.summary not in summaries }}
                              '';
                            }
                          ];
                          sequence = [
                            {
                              service = "button.press";
                              target = {
                                entity_id = "{{ repeat.item.reset_button }}";
                              };
                            }
                          ];
                        }
                      ];
                    }
                  ];
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
                entity_id = [
                  "person.finn"
                  "person.ciara"
                ];
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
                     or ((is_state('person.finn', 'Foodtown')
                          or is_state('person.ciara', 'Foodtown'))
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

          # ── Fridge: write nudges ───────────────────────────────────────
          # Refreshes sensor.fridge_nudges every 30 min and on relevant
          # state changes. The dashboard card gates on the sensor's
          # `valid_until` attribute so the card silently disappears if the
          # script ever fails to refresh.
          {
            alias = "Fridge: write nudges";
            id = "fridge_write_nudges";
            mode = "single";
            trigger = [
              {
                platform = "time_pattern";
                minutes = "/30";
              }
              {
                platform = "state";
                entity_id = [
                  "todo.chores"
                  "todo.foodtown"
                ];
              }
              {
                platform = "state";
                entity_id = [
                  "person.finn"
                  "person.ciara"
                  "person.emily"
                ];
              }
              {
                platform = "calendar";
                event = "start";
                entity_id = "calendar.finn";
              }
              {
                platform = "calendar";
                event = "start";
                entity_id = "calendar.ciara";
              }
              {
                platform = "calendar";
                event = "start";
                entity_id = "calendar.theatre_2";
              }
              {
                platform = "calendar";
                event = "start";
                entity_id = "calendar.holidays_in_united_states";
              }
            ];
            action = [
              {
                service = "shell_command.write_nudges";
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
            # condition = [
            #   {
            #     condition = "state";
            #     entity_id = "input_boolean.guest_mode";
            #     state = "off";
            #   }
            # ];
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
                  brightness_pct = 1;
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
                  brightness_pct = 1;
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

          # ── Welcome home lights ──────────────────────────────────────────
          # When someone arrives home (zone.home transitions from empty to
          # occupied), turn on lights appropriate to the time of day.
          # Skips if Apple TV media lighting is active to avoid interfering
          # with its snapshot/restore cycle.
          {
            alias = "Welcome home lights";
            id = "welcome_home_lights";
            mode = "single";
            trigger = [
              {
                platform = "state";
                entity_id = "zone.home";
                from = "0";
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.guest_mode";
                state = "off";
              }
              {
                condition = "state";
                entity_id = "input_boolean.welcome_home_lights_enabled";
                state = "on";
              }
              # Don't touch lights if ATV media lighting has them adjusted
              {
                condition = "state";
                entity_id = "input_boolean.living_room_appletv_dim_active";
                state = "off";
              }
              # Safety: ensure someone is actually home (defends against
              # stale-state triggers on HA restart)
              {
                condition = "numeric_state";
                entity_id = "zone.home";
                above = "0";
              }
            ];
            action = [
              {
                choose = [
                  # ── Evening: sunset → 10pm ────────────────────────────
                  # Living room dim warm red, corner lamp on.
                  # Bedside lamp intentionally NOT touched.
                  # Fairy lights: Twinkle Stars after 4pm, Clown otherwise.
                  {
                    conditions = [
                      {
                        condition = "sun";
                        after = "sunset";
                      }
                      {
                        condition = "time";
                        before = "22:00:00";
                      }
                    ];
                    sequence = [
                      {
                        service = "light.turn_on";
                        target = {
                          entity_id = "light.living_room";
                        };
                        data = {
                          rgb_color = [
                            255
                            30
                            0
                          ];
                          brightness_pct = 10;
                          transition = 3;
                        };
                      }
                      {
                        service = "light.turn_on";
                        target = {
                          entity_id = "light.smart_led_bulb_2";
                        };
                        data = {
                          brightness_pct = 25;
                          transition = 3;
                        };
                      }
                      {
                        choose = [
                          {
                            conditions = [
                              {
                                condition = "time";
                                after = "16:00:00";
                              }
                            ];
                            sequence = [
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
                        ];
                        default = [
                          {
                            service = "select.select_option";
                            target = {
                              entity_id = "select.fairy_lights_preset";
                            };
                            data = {
                              option = "Clown";
                            };
                          }
                        ];
                      }
                    ];
                  }
                  # ── Late night: 10pm → 6am ────────────────────────────
                  # Hues to Soho scene; corner lamp dim red. No bedside.
                  # Fairy lights: Twinkle Stars after 4pm, Clown otherwise.
                  {
                    conditions = [
                      {
                        condition = "or";
                        conditions = [
                          {
                            condition = "time";
                            after = "22:00:00";
                          }
                          {
                            condition = "time";
                            before = "06:00:00";
                          }
                        ];
                      }
                    ];
                    sequence = [
                      {
                        service = "scene.turn_on";
                        target = {
                          entity_id = "scene.living_room_soho";
                        };
                        data = {
                          transition = 5;
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
                          transition = 5;
                        };
                      }
                      {
                        choose = [
                          {
                            conditions = [
                              {
                                condition = "time";
                                after = "16:00:00";
                              }
                            ];
                            sequence = [
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
                        ];
                        default = [
                          {
                            service = "select.select_option";
                            target = {
                              entity_id = "select.fairy_lights_preset";
                            };
                            data = {
                              option = "Clown";
                            };
                          }
                        ];
                      }
                    ];
                  }
                ];
                # ── Daytime (6am → sunset): only set fairy lights preset ─────────
                default = [
                  {
                    choose = [
                      {
                        conditions = [
                          {
                            condition = "time";
                            after = "16:00:00";
                          }
                        ];
                        sequence = [
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
                    ];
                    default = [
                      {
                        service = "select.select_option";
                        target = {
                          entity_id = "select.fairy_lights_preset";
                        };
                        data = {
                          option = "Clown";
                        };
                      }
                    ];
                  }
                ];
              }
            ];
          }

          # ── All lights off when nobody home ─────────────────────────────
          # When zone.home empties out, kill every light in the house.
          {
            alias = "All lights off when nobody home";
            id = "all_lights_off_when_nobody_home";
            mode = "single";
            trigger = [
              {
                platform = "state";
                entity_id = "zone.home";
                to = "0";
              }
            ];
            condition = [
              {
                condition = "state";
                entity_id = "input_boolean.guest_mode";
                state = "off";
              }
            ];
            action = [
              {
                service = "light.turn_off";
                target = {
                  entity_id = "all";
                };
              }
            ];
          }

          # ── Living Room: media lighting ─────────────────────────────────
          # Apple TV / living_room media player. Three triggers:
          #   playing      → snapshot lights, dim per content class
          #   app_changed  → re-evaluate dim if user switches apps mid-playback
          #   not_playing  → restore the snapshot and clear the flag
          # Content classes: music (skip dim entirely), youtube (corner lamp
          # only), video (corner lamp off + Hue dim/off by sun).
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
              # Fires when the foreground app on the Apple TV changes
              # (e.g. YouTube → Netflix, or Netflix → Apple Music) without
              # leaving the playing state.
              {
                platform = "state";
                entity_id = "media_player.living_room";
                id = "app_changed";
                attribute = "app_id";
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
                  # ── 1. Playback start: classify, snapshot, dim ────────
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
                      # Apple TV populates app_id/media_content_type
                      # asynchronously; wait up to 5 s, then carry on with
                      # whatever's there (the `video` arm is a safe default).
                      {
                        wait_template = "{{ state_attr('media_player.living_room', 'app_id') not in [none, ''] }}";
                        timeout = {
                          seconds = 5;
                        };
                        continue_on_timeout = true;
                      }
                      {
                        variables = {
                          content_class = ''
                            {% set app = state_attr('media_player.living_room', 'app_id') | default(''') | lower %}
                            {% set mtype = state_attr('media_player.living_room', 'media_content_type') | default(''') | lower %}
                            {% set music_apps = ['com.spotify.client', 'com.apple.music', 'com.apple.podcasts', 'com.audible.app'] %}
                            {{ 'music' if (mtype == 'music' or app in music_apps) else ('youtube' if 'youtube' in app else 'video') }}
                          '';
                        };
                      }
                      # Music: bail out before snapshot/flag/dim. Inline
                      # condition stops the sequence cleanly if false.
                      {
                        alias = "Skip if music playback";
                        condition = "template";
                        value_template = "{{ content_class | trim != 'music' }}";
                      }
                      # Snapshot pre-playback state of both lights (incl.
                      # off-state) so restore puts them back exactly.
                      {
                        service = "scene.create";
                        data = {
                          scene_id = "living_room_pre_appletv";
                          snapshot_entities = [
                            "light.living_room"
                            "light.smart_led_bulb_2"
                          ];
                        };
                      }
                      {
                        service = "input_boolean.turn_on";
                        target = {
                          entity_id = "input_boolean.living_room_appletv_dim_active";
                        };
                      }
                      # Apply dim per content_class. YouTube → corner lamp
                      # only; video → corner off + Hue dim (off-darker at
                      # night, half-bright in day).
                      {
                        choose = [
                          {
                            conditions = [
                              {
                                condition = "template";
                                value_template = "{{ content_class | trim == 'youtube' }}";
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
                  # ── 2. App switched mid-playback: re-evaluate dim ─────
                  # Only acts if dim is already active and the TV is still
                  # playing. Music switch → restore + clear flag; otherwise
                  # re-apply the appropriate dim (no re-snapshot).
                  {
                    conditions = [
                      {
                        condition = "trigger";
                        id = "app_changed";
                      }
                      {
                        condition = "state";
                        entity_id = "input_boolean.living_room_appletv_dim_active";
                        state = "on";
                      }
                      {
                        condition = "state";
                        entity_id = "media_player.living_room";
                        state = "playing";
                      }
                    ];
                    sequence = [
                      {
                        wait_template = "{{ state_attr('media_player.living_room', 'app_id') not in [none, ''] }}";
                        timeout = {
                          seconds = 5;
                        };
                        continue_on_timeout = true;
                      }
                      {
                        variables = {
                          content_class = ''
                            {% set app = state_attr('media_player.living_room', 'app_id') | default(''') | lower %}
                            {% set mtype = state_attr('media_player.living_room', 'media_content_type') | default(''') | lower %}
                            {% set music_apps = ['com.spotify.client', 'com.apple.music', 'com.apple.podcasts', 'com.audible.app'] %}
                            {{ 'music' if (mtype == 'music' or app in music_apps) else ('youtube' if 'youtube' in app else 'video') }}
                          '';
                        };
                      }
                      {
                        choose = [
                          # Music: restore snapshot and clear the flag —
                          # treat as "playback ended" for lighting purposes.
                          {
                            conditions = [
                              {
                                condition = "template";
                                value_template = "{{ content_class | trim == 'music' }}";
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
                          # YouTube: corner lamp 15 %, Hue untouched.
                          {
                            conditions = [
                              {
                                condition = "template";
                                value_template = "{{ content_class | trim == 'youtube' }}";
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
                        # Video: corner off + Hue dim per sun.
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
                  # ── 3. Playback ended: restore snapshot + clear flag ──
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
              # Guest mode must be off
              {
                condition = "state";
                entity_id = "input_boolean.guest_mode";
                state = "off";
              }
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

          # ── Guest mode: disable light automations ─────────────────────────
          {
            alias = "Guest mode: disable light automations";
            id = "guest_mode_disable_light_automations";
            mode = "single";
            trigger = [
              {
                platform = "state";
                entity_id = "input_boolean.guest_mode";
                to = "on";
              }
            ];
            action = [
              {
                service = "input_boolean.turn_off";
                target = {
                  entity_id = "input_boolean.welcome_home_lights_enabled";
                };
              }
            ];
          }

          # ── Guest mode: re-enable light automations ───────────────────────
          {
            alias = "Guest mode: re-enable light automations";
            id = "guest_mode_reenable_light_automations";
            mode = "single";
            trigger = [
              {
                platform = "state";
                entity_id = "input_boolean.guest_mode";
                to = "off";
              }
            ];
            action = [
              {
                service = "input_boolean.turn_on";
                target = {
                  entity_id = "input_boolean.welcome_home_lights_enabled";
                };
              }
            ];
          }

          # ── Guest mode: auto-toggle for Emily ────────────────────────────
          # When Emily is home, enable guest mode (suppress automated lights
          # and vacuum). When she leaves, disable guest mode. Also runs on HA
          # restart to recover from stale state.
          {
            alias = "Guest mode: auto-toggle for Emily";
            id = "guest_mode_auto_toggle_emily";
            mode = "single";
            trigger = [
              {
                platform = "state";
                entity_id = "person.emily";
                to = "home";
              }
              {
                platform = "state";
                entity_id = "person.emily";
                from = "home";
              }
              {
                platform = "homeassistant";
                event = "start";
              }
            ];
            action = [
              {
                choose = [
                  {
                    conditions = [
                      {
                        condition = "state";
                        entity_id = "person.emily";
                        state = "home";
                      }
                    ];
                    sequence = [
                      {
                        service = "input_boolean.turn_on";
                        target = {
                          entity_id = "input_boolean.guest_mode";
                        };
                      }
                    ];
                  }
                ];
                default = [
                  {
                    service = "input_boolean.turn_off";
                    target = {
                      entity_id = "input_boolean.guest_mode";
                    };
                  }
                ];
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
            "caldav"
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
            "openweathermap"
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
          #
          # ha_mcp_tools: companion HA integration for the ha-mcp MCP server
          # (modules/iot/ha-mcp.nix). Registers the 5 file/YAML services that
          # back ha-mcp's filesystem + YAML-edit tools. Config-flow only — finish
          # the install once via Settings → Devices & Services → Add Integration.
          # ─────────────────────────────────────────────────────────────────
          customComponents = [
            (withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.hacs))
            pkgs.home-assistant-custom-components.ha_mcp_tools
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
              welcome_home_lights_enabled = {
                name = "Enable welcome home lights";
                icon = "mdi:home-import-outline";
                initial = "on";
              };
              vacuum_auto_skip_today = {
                name = "Skip automatic vacuum today";
                icon = "mdi:robot-vacuum-off";
                initial = "off";
              };
              guest_mode = {
                name = "Guest Mode";
                icon = "mdi:account-group";
                initial = "off";
              };
              vacuum_filter_task_open = {
                name = "Vacuum filter Todoist task open";
                icon = "mdi:air-filter";
                initial = "off";
              };
              vacuum_rolling_brush_task_open = {
                name = "Vacuum rolling brush Todoist task open";
                icon = "mdi:broom";
                initial = "off";
              };
              vacuum_side_brush_task_open = {
                name = "Vacuum side brush Todoist task open";
                icon = "mdi:broom";
                initial = "off";
              };
              vacuum_sensors_task_open = {
                name = "Vacuum sensor cleaning Todoist task open";
                icon = "mdi:eye-check";
                initial = "off";
              };
              vacuum_cleaning_tray_task_open = {
                name = "Vacuum cleaning tray Todoist task open";
                icon = "mdi:tray-alert";
                initial = "off";
              };
              vacuum_mopping_cloth_task_open = {
                name = "Vacuum mopping cloth Todoist task open";
                icon = "mdi:dishwasher";
                initial = "off";
              };
              levoit_filter_task_open = {
                name = "Levoit filter sponges Todoist task open";
                icon = "mdi:air-filter";
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
            # ── CTA train sensors (fall back C → A when C unavailable) ───────────
            template = [
              {
                sensor = [
                  {
                    name = "Kingston-Throop N Next Arrival";
                    unique_id = "kingston_throop_n_next_arrival";
                    state = "{{ states('sensor.c_kingston_throop_avs_n_direction_next_arrival') if states('sensor.c_kingston_throop_avs_n_direction_next_arrival') not in ['','unknown','unavailable','None'] else states('sensor.a_kingston_throop_avs_n_direction_next_arrival') }}";
                    device_class = "timestamp";
                  }
                  {
                    name = "Kingston-Throop N Second Arrival";
                    unique_id = "kingston_throop_n_second_arrival";
                    state = "{{ states('sensor.c_kingston_throop_avs_n_direction_second_arrival') if states('sensor.c_kingston_throop_avs_n_direction_second_arrival') not in ['','unknown','unavailable','None'] else states('sensor.a_kingston_throop_avs_n_direction_second_arrival') }}";
                    device_class = "timestamp";
                  }
                  {
                    name = "Kingston-Throop N Third Arrival";
                    unique_id = "kingston_throop_n_third_arrival";
                    state = "{{ states('sensor.c_kingston_throop_avs_n_direction_third_arrival') if states('sensor.c_kingston_throop_avs_n_direction_third_arrival') not in ['','unknown','unavailable','None'] else states('sensor.a_kingston_throop_avs_n_direction_third_arrival') }}";
                    device_class = "timestamp";
                  }
                ];
              }
              {
                trigger = [
                  {
                    platform = "time_pattern";
                    minutes = "/5";
                  }
                ];
                action = [
                  {
                    service = "weather.get_forecasts";
                    target.entity_id = "weather.openweathermap";
                    data.type = "hourly";
                    response_variable = "forecast";
                  }
                ];
                sensor = [
                  {
                    name = "OpenWeatherMap Peak Rain Chance 12h";
                    unique_id = "owm_peak_rain_chance_12h";
                    state = "{{ forecast['weather.openweathermap'].forecast[:12] | map(attribute='precipitation_probability') | max | default(0) }}";
                    unit_of_measurement = "%";
                  }
                ];
              }
            ];
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
            default_config = { };
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

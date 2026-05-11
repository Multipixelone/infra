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
          hash = "sha256-l75rgkpPOOaDcozG3XI2f2uLrQpDQosbO5h6MIet9BM=";
        };

        # installPhase creates $out/custom_components/hacs — the layout the
        # service preStart uses when symlinking into the HA config dir.
        installPhase = ''
          mkdir -p $out/custom_components
          mv hacs $out/custom_components/
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

      services.home-assistant = {
        enable = true;
        openFirewall = true;
        extraComponents = [
          "mobile_app"
          "webhook"
          "default_config"
          "google_translate"
          "hue"
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
            aionanoleaf
            led-ble
            hueble
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
            eufyVacuumEntityId = "vacuum.robovac_x10_pro_omni"; # TODO: replace
            eufyWaterLevelSensor = "sensor.robovac_x10_pro_omni_water_level"; # TODO: replace
            eufyErrorSensor = "sensor.robovac_x10_pro_omni_error"; # TODO: replace
            levoitWaterSensor = "binary_sensor.levoit_humidifier_water_lacks"; # TODO: verify entity_id
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
              eufy_water_refilled = {
                name = "Eufy water refilled — clear task flag";
                icon = "mdi:water-check";
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

              # ── Eufy: water guard — return to base if water critically low ──
              # Sends vacuum back to dock automatically when water is below 15%.
              {
                alias = "Eufy: Guard — return to base if water critically low";
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
                    service = "vacuum.return_to_base";
                    target = {
                      entity_id = eufyVacuumEntityId;
                    };
                  }
                  {
                    delay = {
                      seconds = 5;
                    };
                  }
                  {
                    service = "todoist.new_task";
                    data = {
                      content = "Refill Eufy vacuum water tank";
                      description = "Refill tank before starting the next cycle. (Status: Returned to base)";
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

              # ── Eufy: reset dedupe flag when user refills ───────────────────
              # Toggle input_boolean.eufy_water_refilled in the HA UI after
              # refilling the water tank to clear the warning flag and allow
              # future tasks to be created.
              {
                alias = "Eufy: Water refilled — reset warning flag";
                id = "eufy_water_refilled";
                trigger = [
                  {
                    platform = "state";
                    entity_id = "input_boolean.eufy_water_refilled";
                    to = "on";
                  }
                ];
                action = [
                  {
                    service = "input_boolean.turn_off";
                    target = {
                      entity_id = "input_boolean.eufy_water_task_open";
                    };
                  }
                  {
                    service = "input_boolean.turn_off";
                    target = {
                      entity_id = "input_boolean.eufy_water_refilled";
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
                      description = "Refill tank to prevent cleaning interruptions. (Status: Low water warning)";
                      labels = todoistLabel;
                      priority = 2;
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

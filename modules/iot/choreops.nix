# One-time seed script for ChoreOps consumable chores.
#
# ChoreOps state is storage-backed (.storage/choreops), not declarative — chores
# are created by calling `choreops.create_chore`, not by editing Nix. This script
# documents the 7 consumable chore definitions in-repo and creates them in a
# single run. Trigger it ONCE via `script.choreops_seed_consumable_chores`
# (HA UI or ha_call_service); re-running would create duplicate chores.
#
# Assignment split: chores that involve buying/swapping a part are Finn-only
# (the household doesn't want roommates purchasing parts); cleaning chores stay
# shared. Finn-only chores use completion_criteria "independent" — ChoreOps adds
# no global-status sensor for them, so completion shows on
# `sensor.finn_choreops_chore_status_<slug>`. Shared chores use "shared_first",
# which exposes `sensor.office_system_choreops_<slug>_global_status`.
#
# The Eufy/Levoit telemetry automations in homeassistant.nix make these chores
# due via `choreops.set_chore_due_date`; the reverse completion-sync there
# presses the matching Eufy hardware reset button when a chore is completed.
{
  configurations.nixos.iot.module =
    let
      mkChore =
        {
          name,
          icon,
          points,
          completion_criteria,
          assigned,
          description,
        }:
        {
          service = "choreops.create_chore";
          data = {
            inherit
              name
              icon
              points
              description
              ;
            assigned_user_names = assigned;
            inherit completion_criteria;
            # Mirror the existing water chores: clear the due date immediately
            # once the chore goes late, and reset approvals at midnight.
            overdue_handling = "at_due_date_clear_immediate_on_late";
            approval_reset_type = "at_midnight_once";
          };
        };

      shared = [
        "Finn"
        "Ciara"
        "Holland"
      ];
      finn = [ "Finn" ];

      chores = [
        # ── Shared cleaning chores (no purchase) ──
        {
          name = "Clean Vacuum Nav Sensors";
          icon = "mdi:eye-check";
          points = 5;
          completion_criteria = "shared_first";
          assigned = shared;
          description = "Wipe the vacuum's IR/cliff nav sensors with a dry microfibre cloth.";
        }
        {
          name = "Clean Vacuum Cleaning Tray";
          icon = "mdi:tray-alert";
          points = 5;
          completion_criteria = "shared_first";
          assigned = shared;
          description = "Rinse the vacuum mopping tray and clear any debris.";
        }
        {
          name = "Wash Vacuum Mop Cloth";
          icon = "mdi:dishwasher";
          points = 5;
          completion_criteria = "shared_first";
          assigned = shared;
          description = "Wash the vacuum mopping cloth (or replace if worn).";
        }
        # ── Finn-only chores (buying/swapping a part) ──
        {
          name = "Replace Vacuum HEPA Filter";
          icon = "mdi:air-filter";
          points = 10;
          completion_criteria = "independent";
          assigned = finn;
          description = "Install a new HEPA filter in the vacuum.";
        }
        {
          name = "Replace Vacuum Rolling Brush";
          icon = "mdi:broom";
          points = 10;
          completion_criteria = "independent";
          assigned = finn;
          description = "Install a new rolling brush in the vacuum.";
        }
        {
          name = "Replace Vacuum Side Brush";
          icon = "mdi:broom";
          points = 8;
          completion_criteria = "independent";
          assigned = finn;
          description = "Install a new side brush in the vacuum.";
        }
        {
          name = "Order Levoit Filter Sponges";
          icon = "mdi:air-filter";
          points = 3;
          completion_criteria = "independent";
          assigned = finn;
          description = "Order replacement Levoit humidifier filter sponges.";
        }
      ];
    in
    {
      iotHass.nixScripts = [
        {
          id = "choreops_seed_consumable_chores";
          alias = "ChoreOps — seed consumable chores";
          description = ''
            One-time: create the 7 consumable ChoreOps chores (3 shared cleaning,
            4 Finn-only replace/order) that the Eufy/Levoit telemetry automations
            make due. Run exactly once — re-running creates duplicate chores.
          '';
          mode = "single";
          icon = "mdi:playlist-plus";
          sequence = map mkChore chores;
        }
      ];
    };
}

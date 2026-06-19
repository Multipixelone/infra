# One-time seed script for ChoreOps consumable chores.
#
# ChoreOps state is storage-backed (.storage/choreops), not declarative — chores
# are created by calling `choreops.create_chore`, not by editing Nix. This script
# documents the 7 consumable chore definitions in-repo and creates them in a
# single run. Trigger it ONCE via `script.choreops_seed_consumable_chores`
# (HA UI or ha_call_service); re-running would create duplicate chores.
#
# Assignment split: only the part-purchasing chore (Order Levoit Filter Sponges)
# is Finn-only — the household doesn't want roommates purchasing parts. Part-swap
# chores (filter/brush installs) and cleaning chores are shared. The Finn-only
# order chore uses completion_criteria "independent" — ChoreOps adds no
# global-status sensor for it, so completion shows on
# `sensor.finn_choreops_chore_status_<slug>`. Cleaning chores use "shared_first"
# (exposing `sensor.office_system_choreops_<slug>_global_status`); part-swap
# chores use "rotation_primary_standby" with Finn as primary and the roommates as
# standbys who can claim once the chore is overdue (standby_claim_mode
# "on_overdue"). Primary/standby chores expose NO global-status sensor; the
# overall state is mirrored as the `global_state` attribute on each assignee's
# `sensor.<user>_choreops_chore_status_<slug>`.
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
          standby_claim_mode ? null,
          # Default mirrors the water chores: clear the due date immediately once
          # the chore goes late. The primary/standby part-swap chores override
          # this to "at_due_date" so the chore persists while overdue and a
          # standby can still claim it for the points.
          overdue_handling ? "at_due_date_clear_immediate_on_late",
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
            # Reset approvals at midnight.
            inherit completion_criteria overdue_handling;
            approval_reset_type = "at_midnight_once";
          }
          # standby_claim_mode only applies to rotation_primary_standby chores.
          // (if standby_claim_mode == null then { } else { inherit standby_claim_mode; });
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
          points = 3;
          completion_criteria = "shared_first";
          assigned = shared;
          description = "Wipe the vacuum's IR/cliff nav sensors with a dry microfibre cloth.";
        }
        {
          name = "Clean Vacuum Cleaning Tray";
          icon = "mdi:tray-alert";
          points = 3;
          completion_criteria = "shared_first";
          assigned = shared;
          description = "Rinse the vacuum mopping tray and clear any debris.";
        }
        {
          name = "Wash Vacuum Mop Cloth";
          icon = "mdi:dishwasher";
          points = 4;
          completion_criteria = "shared_first";
          assigned = shared;
          description = "Wash the vacuum mopping cloth (or replace if worn).";
        }
        # ── Shared part-swap chores (Finn primary, roommates standby) ──
        # Finn normally does these, but if he lets one go overdue a roommate can
        # claim it for the points. Installing a part Finn already bought is fine
        # to share — only the purchasing chore below stays Finn-only.
        {
          name = "Replace Vacuum HEPA Filter";
          icon = "mdi:air-filter";
          points = 5;
          completion_criteria = "rotation_primary_standby";
          assigned = shared;
          standby_claim_mode = "on_overdue";
          overdue_handling = "at_due_date";
          description = "Install a new HEPA filter in the vacuum.";
        }
        {
          name = "Replace Vacuum Rolling Brush";
          icon = "mdi:broom";
          points = 5;
          completion_criteria = "rotation_primary_standby";
          assigned = shared;
          standby_claim_mode = "on_overdue";
          overdue_handling = "at_due_date";
          description = "Install a new rolling brush in the vacuum.";
        }
        {
          name = "Replace Vacuum Side Brush";
          icon = "mdi:broom";
          points = 4;
          completion_criteria = "rotation_primary_standby";
          assigned = shared;
          standby_claim_mode = "on_overdue";
          overdue_handling = "at_due_date";
          description = "Install a new side brush in the vacuum.";
        }
        # ── Finn-only chore (purchasing a part) ──
        {
          name = "Order Levoit Filter Sponges";
          icon = "mdi:air-filter";
          points = 2;
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
            3 shared part-swap with Finn as primary, 1 Finn-only order) that the
            Eufy/Levoit telemetry automations make due. Run exactly once —
            re-running creates duplicate chores.
          '';
          mode = "single";
          icon = "mdi:playlist-plus";
          sequence = map mkChore chores;
        }
      ];
    };
}

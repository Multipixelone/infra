# roomieorder — Home Assistant buttons + dashboard, generated from catalog.json.
#
# Do NOT hand-write a button list. `roomieorder.lib.haButtons` turns
# catalog.json into the rest_command + per-item scripts + status sensors + a
# Lovelace grid, so catalog.json (shared with the service on link via
# inputs.secrets) stays the single source of truth: ADD A STAPLE THERE AND ITS
# BUTTON APPEARS ON THE DASHBOARD — that catalog edit is the *only* step.
#
# This host routes Nix-managed scripts through iotHass.nixScripts (separate from
# the UI-managed scripts.yaml), so we feed `.scripts` (a list), not
# `.scriptsAttrs`. rest_command + rest are plain config and need no include-split.
#
# The visible buttons live on a dedicated, Nix-managed "Reorder" Lovelace
# dashboard (YAML mode) — generated here from buttons.dashboardCardHousehold (the
# SHARED grid, with any owner-tagged personal items filtered out) — so they
# regenerate on every rebuild with no manual ha-mcp push. The iPad kiosk
# (main-home, storage mode / UI-managed) is left untouched.
#
# A catalog item with an `owner` (e.g. "owner": "Finn") is a roommate's personal
# buy: it drops off the shared Reorder grid and onto that owner's own dashboard.
# This module exposes the generated grids as `_module.args.roomieorderButtons`;
# Finn's personal grid (buttons.dashboardCardsByOwner."Finn") is then folded into
# his EXISTING dashboard in dashboard-home.nix rather than a new one here.
{ inputs, config, ... }:
let
  buttons = inputs.roomieorder.lib.haButtons {
    # Same file the service on link loads (modules/link/roomieorder.nix).
    catalogFile = "${inputs.secrets}/roomieorder/catalog.json";
    # link's LAN address + intake port (see ROOMIEORDER_HOST/PORT on link).
    endpoint = "http://${config.hosts.link.homeAddress}:8723";
    # requester defaults to "household" — no per-roommate attribution.
  };
in
{
  configurations.nixos.iot.module =
    { pkgs, ... }:
    let
      yamlFormat = pkgs.formats.yaml { };

      # The dynamic grid uses custom:mushroom-template-card (gray-out + "N ago"),
      # so the mushroom frontend must be loaded. mushroom (and every other custom
      # module on iot) is declared once in dashboard-home.nix's
      # customLovelaceModules list — the single source of truth for frontend
      # resources — so we do NOT re-declare it here (that would emit a duplicate
      # lovelace.resources entry). The HA module serves it at
      # /local/nixos-lovelace-modules/mushroom.js and auto-sets
      # lovelace.resource_mode = "yaml", which loads the JS for this dashboard too.

      # One YAML-mode dashboard, one view, the catalog-derived dynamic grid.
      # yamlFormat.generate's out path IS the .yaml file, so we can point HA's
      # `filename` straight at the store path (it ends in .yaml and HA resolves an
      # absolute filename as-is). Changing catalog.json changes this derivation,
      # which trips the reloadTrigger below.
      reorderDashboard = yamlFormat.generate "lovelace-reorder.yaml" {
        title = "Reorder";
        views = [
          {
            title = "Reorder";
            path = "reorder";
            icon = "mdi:cart";
            cards = [
              # Back to the kiosk home view (the kiosk has no sidebar). The
              # nixos-home dashboard's Reorder chip navigates here.
              {
                type = "custom:mushroom-chips-card";
                alignment = "start";
                chips = [
                  {
                    type = "template";
                    icon = "mdi:arrow-left";
                    content = "Back";
                    tap_action = {
                      action = "navigate";
                      navigation_path = "/nixos-home/home?kiosk";
                    };
                  }
                ];
              }
              # The SHARED grid: every staple EXCEPT owner-tagged personal items.
              # Each owner's personal items render on their own dashboard instead
              # — Finn's are folded into his existing dashboard (dashboard-home.nix),
              # which reads buttons.dashboardCardsByOwner via _module.args below.
              buttons.dashboardCardHousehold
            ];
          }
        ];
      };
    in
    {
      # Share the generated grids with the other iot dashboard modules (so
      # dashboard-home.nix can splice the per-owner grid into Finn's existing
      # dashboard rather than this module standing up a second one).
      _module.args.roomieorderButtons = buttons;

      services.home-assistant.config = {
        rest_command = buttons.restCommand;
        # Per-item status sensors (one GET /items poll, one sensor per item) that
        # drive the dashboard gray-out: each sensor.roomieorder_<key> carries an
        # `on_cooldown` attribute, true while the item is inside its catalog
        # cooldown window of the last *placed* order. `rest` is a top-level list
        # and nothing else on iot defines it, so this is the sole `rest:` block.
        rest = buttons.sensors;

        lovelace = {
          # Default dashboard (main-home, the iPad kiosk) stays storage mode /
          # UI-managed — that's HA's default, so `lovelace.mode` is left unset
          # (the module deprecated it). resource_mode = "yaml" (auto, from
          # customLovelaceModules) still loads the mushroom resource, so the
          # dynamic cards render here.
          # The generated, self-updating Reorder dashboard. A separate sidebar
          # entry; does not touch the kiosk. (Finn's personal items live on his
          # existing dashboard, not here — see dashboard-home.nix.)
          dashboards.nixos-reorder = {
            mode = "yaml";
            filename = "${reorderDashboard}";
            title = "Reorder";
            icon = "mdi:cart";
            show_in_sidebar = true;
          };
        };
      };

      iotHass.nixScripts = buttons.scripts;

      # Pick up dashboard changes (a catalog edit) on rebuild without a manual
      # reload. Mirrors how homeassistant.nix triggers on its generated YAML.
      systemd.services.home-assistant.reloadTriggers = [ reorderDashboard ];
    };
}

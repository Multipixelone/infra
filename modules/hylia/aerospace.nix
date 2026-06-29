{ lib, ... }:
let
  # $mod+{1..10} → workspace N ; $mod+SHIFT+{1..10} → move window to N.
  # (Hyprland workspace / movetoworkspacesilent binds; key 0 = workspace 10.)
  workspaceBinds = lib.foldl' (
    acc: i:
    let
      n = toString i;
      key = if i == 10 then "0" else n;
    in
    acc
    // {
      "alt-${key}" = "workspace ${n}";
      "alt-shift-${key}" = "move-node-to-workspace ${n}";
    }
  ) { } (lib.range 1 10);
in
{
  configurations.darwin.hylia.module = {
    # AeroSpace: tiling WM porting the window-management half of the Hyprland
    # binds (modules/hyprland/conf/binds.nix). App launches stay in skhd.nix;
    # AeroSpace owns focus / move / resize / workspaces. $mod = alt (Hyprland).
    # NOTE: needs Accessibility granted once; works best with System Settings →
    # Desktop & Dock → Mission Control → "Displays have separate Spaces" OFF.
    services.aerospace = {
      enable = true;
      settings = {
        gaps = {
          inner.horizontal = 8;
          inner.vertical = 8;
          outer = {
            left = 8;
            right = 8;
            top = 8;
            bottom = 8;
          };
        };
        mode.main.binding = {
          # focus  (Hyprland $mod + h/j/k/l → movefocus)
          alt-h = "focus left";
          alt-j = "focus down";
          alt-k = "focus up";
          alt-l = "focus right";
          # move window  (Hyprland $mod+SHIFT → movewindow)
          alt-shift-h = "move left";
          alt-shift-j = "move down";
          alt-shift-k = "move up";
          alt-shift-l = "move right";
          # resize  (Hyprland Alt_Super → resizeactive)
          alt-cmd-h = "resize width -80";
          alt-cmd-l = "resize width +80";
          alt-cmd-k = "resize height -80";
          alt-cmd-j = "resize height +80";
          # layout  ($mod+s togglesplit · $mod+v togglefloating · SUPER+F fullscreen)
          alt-s = "layout tiles horizontal vertical";
          alt-v = "layout floating tiling";
          alt-f = "fullscreen"; # was SUPER+F; cmd-f would swallow macOS Find globally
          # ALT+Tab → previous workspace
          alt-tab = "workspace-back-and-forth";
          # move current workspace between monitors
          # (Hyprland $mod+SHIFT+ALT + bracketleft/right → l/r monitor)
          alt-shift-cmd-h = "move-workspace-to-monitor --wrap-around prev";
          alt-shift-cmd-l = "move-workspace-to-monitor --wrap-around next";
          # reload after editing this file + switching
          alt-shift-c = "reload-config";
        }
        // workspaceBinds;
      };
    };
  };
}

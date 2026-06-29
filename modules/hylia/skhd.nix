{
  configurations.darwin.hylia.module = {
    # skhd: hotkey daemon ported from the Hyprland binds in
    # modules/hyprland/conf/binds.nix. Only the app-launch / exec binds map to
    # macOS — window management ($mod+h/j/k/l focus & move, resize, workspaces
    # 1-10, togglefloating, fullscreen) is handled by Rectangle + native Spaces,
    # not skhd. For true tiling parity you'd add aerospace or yabai.
    #
    # Modifier parity: Hyprland $mod = ALT → `alt`; SUPER → `cmd`.
    # NOTE: skhd needs Accessibility + Input Monitoring granted once in
    # System Settings → Privacy & Security before bindings fire.
    services.skhd = {
      enable = true;
      skhdConfig = ''
        # --- terminal / files ---
        # `open -na` forces a new instance so Ghostty spawns a *new window*
        # instead of just refocusing the existing one.
        alt - return        : open -na Ghostty                         # $mod+RETURN (foot)
        cmd - e             : open -na Ghostty --args -e fish -c yazi   # SUPER+E (yazi)

        # --- apps ---
        alt + shift - w     : open -a Firefox                          # ALT_SHIFT+W
        alt + shift - d     : open -a Discord                          # ALT_SHIFT+D
        alt + shift - s     : open -a Slack                            # ALT_SHIFT+S
        alt + shift - o     : open -a Obsidian                         # ALT_SHIFT+O
        alt + shift - n     : open -a Notion                           # ALT_SHIFT+N

        # --- "scratchpad" equivalents (pypr toggles → focus/launch app) ---
        ctrl + alt - k      : open -a "1Password"                      # pypr password
        ctrl + alt - m      : open -a Spotify                          # pypr music
        ctrl + alt - g      : open -a Fluso                            # pypr gpt

        # --- system ---
        # Lock the screen (Hyprland had a hyprlock bind).
        ctrl + alt - q      : pmset displaysleepnow

        # Launcher: Hyprland $mod+SPACE opens anyrun. On macOS bind the
        # equivalent inside Alfred (Alfred → Preferences → hotkey), since the
        # search bar has no stable CLI trigger for skhd to call.
        #
        # Screenshots: Hyprland uses Print; macOS has native cmd+shift+3/4/5.
      '';
    };
  };
}

{ inputs, ... }:
{
  flake-file.inputs = {
    zjstatus.url = "github:dj95/zjstatus";
    zjstatus-hints = {
      url = "github:b0o/zjstatus-hints";
      inputs.rust-overlay.follows = "monocle/rust-overlay";
    };
    monocle.url = "github:Multipixelone/monocle/nix-build";
    zsm.url = "github:Multipixelone/zsm/nix-build";
    room.url = "github:Multipixelone/room/reduce-binary-size";
  };
  flake.modules.homeManager.base =
    hmArgs@{
      pkgs,
      ...
    }:
    let
      zjstatus = inputs.zjstatus.packages.${pkgs.stdenv.hostPlatform.system}.default;
      monocle = inputs.monocle.packages.${pkgs.stdenv.hostPlatform.system}.default;
      zsm = inputs.zsm.packages.${pkgs.stdenv.hostPlatform.system}.default;
      zjstatus-hints = inputs.zjstatus-hints.packages.${pkgs.stdenv.hostPlatform.system}.default;
      room = inputs.room.packages.${pkgs.stdenv.hostPlatform.system}.default;
      inherit (hmArgs.config.lib.stylix) colors;
      zjstatus-conf = ''
        plugin location="zjstatus" {
            format_left   "{mode}{tabs} #[fg=#6C7086,italic]@{session} {notifications}"
            format_center ""
            format_right  "{pipe_zjstatus_hints}#[fg=#${colors.base05},bold]"
            format_space  ""
            format_hide_on_overlength "true"
            format_precedence "lrc"

            notification_format_unread           "#[fg=#89B4FA,blink,bold]!#[fg=#89B4FA] {message} "
            notification_format_no_notifications "#[fg=#494d64,dim]"
            notification_show_interval           "7"

            pipe_zjstatus_hints_format "#[bg=#cba6f7,fg=#1e1e2e,bold] {output} "

            border_enabled  "false"
            border_char     "─"
            border_format   "#[fg=#6C7086]{char}"
            border_position "top"

            mode_normal        ""
            mode_locked        "#[fg=#${colors.base04}]#[bg=#${colors.base04},fg=#${colors.base02},bold]LOCKED #[fg=#${colors.base04}] "
            mode_resize        "#[fg=#${colors.base08}]#[bg=#${colors.base08},fg=#${colors.base02},bold]RESIZE#[fg=#${colors.base08}] "
            mode_pane          "#[fg=#${colors.base0D}]#[bg=#${colors.base0D},fg=#${colors.base02},bold]PANE#[fg=#${colors.base0D}] "
            mode_tab           "#[fg=#${colors.base07}]#[bg=#${colors.base07},fg=#${colors.base02},bold]TAB#[fg=#${colors.base07}] "
            mode_scroll        "#[fg=#${colors.base0A}]#[bg=#${colors.base0A},fg=#${colors.base02},bold]SCROLL#[fg=#${colors.base0A}] "
            mode_enter_search  "#[fg=#${colors.base0D}]#[bg=#${colors.base0D},fg=#${colors.base02},bold]ENT-SEARCH#[fg=#${colors.base0D}] "
            mode_search        "#[fg=#${colors.base0D}]#[bg=#${colors.base0D},fg=#${colors.base02},bold]SEARCH#[fg=#${colors.base0D}] "
            mode_rename_tab    "#[fg=#${colors.base07}]#[bg=#${colors.base07},fg=#${colors.base02},bold]RENAME-TAB#[fg=#${colors.base07}] "
            mode_rename_pane   "#[fg=#${colors.base0D}]#[bg=#${colors.base0D},fg=#${colors.base02},bold]RENAME-PANE#[fg=#${colors.base0D}] "
            mode_session       "#[fg=#${colors.base0E}]#[bg=#${colors.base0E},fg=#${colors.base02},bold]SESSION#[fg=#${colors.base0E}] "
            mode_move          "#[fg=#${colors.base0F}]#[bg=#${colors.base0F},fg=#${colors.base02},bold]MOVE#[fg=#${colors.base0F}] "
            mode_prompt        "#[fg=#${colors.base0D}]#[bg=#${colors.base0D},fg=#${colors.base02},bold]PROMPT#[fg=#${colors.base0D}] "
            mode_tmux          "#[fg=#${colors.base09}]#[bg=#${colors.base09},fg=#${colors.base02},bold]TMUX#[fg=#${colors.base09}] "

            // formatting for inactive tabs
            tab_normal              "#[fg=#${colors.base0D}]#[bg=#${colors.base0D},fg=#${colors.base02},bold]{index} #[bg=#${colors.base02},fg=#${colors.base05},bold] {name}{floating_indicator}#[fg=#${colors.base02},bold]"
            tab_normal_fullscreen   "#[fg=#${colors.base0D}]#[bg=#${colors.base0D},fg=#${colors.base02},bold]{index} #[bg=#${colors.base02},fg=#${colors.base05},bold] {name}{fullscreen_indicator}#[fg=#${colors.base02},bold]"
            tab_normal_sync         "#[fg=#${colors.base0D}]#[bg=#${colors.base0D},fg=#${colors.base02},bold]{index} #[bg=#${colors.base02},fg=#${colors.base05},bold] {name}{sync_indicator}#[fg=#${colors.base02},bold]"

            // formatting for the current active tab
            tab_active              "#[fg=#${colors.base09}]#[bg=#${colors.base09},fg=#${colors.base02},bold]{index} #[bg=#${colors.base02},fg=#${colors.base05},bold] {name}{floating_indicator}#[fg=#${colors.base02},bold]"
            tab_active_fullscreen   "#[fg=#${colors.base09}]#[bg=#${colors.base09},fg=#${colors.base02},bold]{index} #[bg=#${colors.base02},fg=#${colors.base05},bold] {name}{fullscreen_indicator}#[fg=#${colors.base02},bold]"
            tab_active_sync         "#[fg=#${colors.base09}]#[bg=#${colors.base09},fg=#${colors.base02},bold]{index} #[bg=#${colors.base02},fg=#${colors.base05},bold] {name}{sync_indicator}#[fg=#${colors.base02},bold]"

            // separator between the tabs
            tab_separator           " "

            // indicators
            tab_sync_indicator       " "
            tab_fullscreen_indicator " 󰊓"
            tab_floating_indicator   " 󰹙"

            command_git_branch_command     "git rev-parse --abbrev-ref HEAD"
            command_git_branch_format      "#[fg=blue] {stdout} "
            command_git_branch_interval    "10"
            command_git_branch_rendermode  "static"

            datetime        "#[fg=#6C7086,bold] {format} "
            datetime_format "%A, %d %b %Y %H:%M"
            datetime_timezone "America/New_York"
          }
      '';
    in
    {
      programs.zellij = {
        inherit (hmArgs.config.home.shell) enableFishIntegration;
        enable = true;
      };
      xdg.configFile = {
        "zellij/config.kdl".text = ''
          theme "default"
          default_layout "zjstatus"
          pane_frames false
          show_startup_tips false
          plugins {
              zjstatus location="file://${zjstatus}/bin/zjstatus.wasm"
              zjstatus-hints location="file://${zjstatus-hints}/bin/zjstatus-hints.wasm" {
                max_length 0
                overflow_str "..."
                pipe_name "zjstatus_hints"
                hide_in_base_mode false
            }
          }
          load_plugins {
            zjstatus-hints
          }
          keybinds {
            shared {
              bind "Ctrl Tab" { GoToNextTab; }
              bind "Ctrl Shift Tab" { GoToPreviousTab; }
              bind "Alt Enter" { NewPane "Right"; SwitchToMode "Normal"; }
              bind "Alt Shift Q" { CloseFocus; SwitchToMode "Normal"; }
              bind "Alt Shift Enter" { NewPane "Down"; SwitchToMode "Normal"; }
              bind "Alt m" {
                LaunchPlugin "file://${monocle}/bin/monocle.wasm" {
                  in_place true
                  kiosk true
                };
                SwitchToMode "Normal"
              }
              bind "Alt r" {
                LaunchOrFocusPlugin "file://${room}/lib/zellij/plugins/room.wasm" {
                  floating true
                  ignore_case true
                  quick_jump true
                };
                SwitchToMode "Normal"
              }
              bind "Alt z" {
                LaunchOrFocusPlugin "file://${zsm}/bin/zsm.wasm" {
                  floating true
                  move_to_focused_tab true
                  show_resurrectable_sessions true
                  session_seperator "-"
                  base_paths "/home/tunnel/Documents/Git|/volume1/Media"
                  default_layout "zjstatus"
                }
              }
            }
            shared_except "locked" {
              bind "Alt f" { ToggleFloatingPanes; SwitchToMode "Normal"; }
              bind "Alt Shift F" { TogglePaneEmbedOrFloating; SwitchToMode "Normal"; }
              bind "Alt e" { EditScrollback; SwitchToMode "Normal"; }
              bind "Alt h" { MoveFocus "Left"; }
              bind "Alt l" { MoveFocus "Right"; }
              bind "Alt j" { MoveFocus "Down"; }
              bind "Alt k" { MoveFocus "Up"; }
            }
          }
        '';
        "zellij/layouts/zjstatus.kdl".text = ''
          layout {
              default_tab_template {
                  pane size=2 borderless=true {
                    ${zjstatus-conf}
                  }
                  children
              }
          }
        '';
      };
    };
}

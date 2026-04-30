{
  flake.modules.homeManager.base =
    {
      pkgs,
      lib,
      osConfig,
      hosts,
      ...
    }:
    let
      isLink = (osConfig.networking.hostName or "") == "link";
      mpdAddress = if isLink then "127.0.0.1:6600" else "${hosts.link.homeAddress}:6600";
      # NOTE probably not using this, but i'm leaving it here for posterity cause I'm gonna forget how to wrap a shell script in the future LMAO
      # kunst = pkgs.stdenv.mkDerivation rec {
      #   name = "kunst";
      #   nativeBuildInputs = [pkgs.makeWrapper];
      #   buildInputs = with pkgs; [
      #     bash
      #     ffmpeg-headless
      #     imagemagick
      #     jq
      #     mpc
      #     mpd
      #     nsxiv
      #   ];
      #   src = pkgs.fetchFromGitHub {
      #     owner = "sdushantha";
      #     repo = "kunst";
      #     rev = "5149471925b6f2239b2fa5873370e297fc6b0bea";
      #     hash = "sha256-vSAp1T1Q28sPCE2BffCxBCZwyZG2VYeoC7XjZPCX2yM=";
      #   };
      #   installPhase = ''
      #     install -Dm755 ${src}/kunst $out/bin/kunst
      #     wrapProgram $out/bin/kunst --prefix PATH : '${lib.makeBinPath buildInputs}'
      #   '';
      # };
      song-change = pkgs.writeShellApplication {
        name = "song-change";
        runtimeInputs = with pkgs; [
          libnotify
          rmpc
          procps
        ];
        text = ''
          COVER=/tmp/waybar-mediaplayer-art.jpg

          # get cover out of rmpc
          rmpc albumart --output "$COVER"
          notify-send -r 27072 -i "''${COVER}" "$TITLE" "by $ARTIST on $ALBUM"

          sleep 5
          # update waybar
          pkill -RTMIN+5 waybar || true
          # update hyprlock
          pkill -USR2 hyprlock || true
        '';
      };
    in
    {
      programs.rmpc.enable = true;
      home.packages = [
        song-change
        pkgs.cava
      ];
      xdg.desktopEntries."rmpc" = {
        name = "rmpc";
        comment = "rmpc music player";
        exec = "uwsm app -- foot -a foot-music rmpc";
        terminal = false;
        type = "Application";
        icon = "apple-music";
      };
      xdg.configFile = {
        "rmpc/themes/cat.ron".text = ''
          #![enable(implicit_some)]
          #![enable(unwrap_newtypes)]
          #![enable(unwrap_variant_newtypes)]
          (
              default_album_art_path: None,
              draw_borders: false,
              show_song_table_header: false,
              symbols: (song: "🎵", dir: "📁", playlist: "🎼", marker: "\u{e0b0}"),
              layout: Split(
                  direction: Vertical,
                  panes: [
                      (
                          pane: Pane(Header),
                          size: "1",
                      ),
                      (
                          pane: Pane(TabContent),
                          size: "100%",
                      ),
                      (
                          pane: Pane(ProgressBar),
                          size: "1",
                      ),
                  ],
              ),
              progress_bar: (
                  symbols: ["█", "█", "█", "█", "█"],
                  track_style: (bg: "#1e2030"),
                  elapsed_style: (fg: "#c6a0f6", bg: "#1e2030"),
                  thumb_style: (fg: "#c6a0f6", bg: "#1e2030"),
              ),
              scrollbar: (
                  symbols: ["│", "█", "▲", "▼"],
                  track_style: (),
                  ends_style: (),
                  thumb_style: (fg: "#b7bdf8"),
              ),
              cava: (
                  bar_width: 2,
                  bar_spacing: 1,
                  orientation: Bottom,
                  bar_color: Gradient({
                        0: "#FF2D7D",
                       14: "#FF4FA3",
                       28: "#FF6EC7",
                       42: "#D67EFF",
                       56: "#9D8AFF",
                       70: "#6A9AFF",
                       84: "#38B6FF",
                      100: "#00D0E0",
                  }),
              ),
              browser_column_widths: [20, 38, 42],
              text_color: "#cad3f5",
              background_color: "#24273a",
              header_background_color: "#1e2030",
              modal_background_color: None,
              modal_backdrop: false,
              tab_bar: (active_style: (fg: "black", bg: "#c6a0f6", modifiers: "Bold"), inactive_style: ()),
              borders_style: (fg: "#6e738d"),
              highlighted_item_style: (fg: "#c6a0f6", modifiers: "Bold"),
              current_item_style: (fg: "black", bg: "#b7bdf8", modifiers: "Bold"),
              highlight_border_style: (fg: "#b7bdf8"),
              song_table_format: [
                  (
                      prop: (kind: Property(Artist), style: (fg: "#b7bdf8"), default: (kind: Text("Unknown"))),
                      width: "50%",
                      alignment: Right,
                  ),
                  (
                      prop: (kind: Text("-"), style: (fg: "#b7bdf8"), default: (kind: Text("Unknown"))),
                      width: "1",
                      alignment: Center,
                  ),
                  (
                      prop: (kind: Property(Title), style: (fg: "#7dc4e4"), default: (kind: Text("Unknown"))),
                      width: "50%",
                  ),
              ],
              header: (
                  rows: [
                      (
                          left: [
                              (kind: Text("["), style: (fg: "#b7bdf8", modifiers: "Bold")),
                              (kind: Property(Status(State)), style: (fg: "#b7bdf8", modifiers: "Bold")),
                              (kind: Text("]"), style: (fg: "#b7bdf8", modifiers: "Bold"))
                          ],
                          center: [
                              (kind: Property(Song(Artist)), style: (fg: "#eed49f", modifiers: "Bold"),
                                  default: (kind: Text("Unknown"), style: (fg: "#eed49f", modifiers: "Bold"))
                              ),
                              (kind: Text(" - ")),
                              (kind: Property(Song(Title)), style: (fg: "#7dc4e4", modifiers: "Bold"),
                                  default: (kind: Text("No Song"), style: (fg: "#7dc4e4", modifiers: "Bold"))
                              )
                          ],
                          right: [
                              (kind: Text("Vol: "), style: (fg: "#b7bdf8", modifiers: "Bold")),
                              (kind: Property(Status(Volume)), style: (fg: "#b7bdf8", modifiers: "Bold")),
                              (kind: Text("% "), style: (fg: "#b7bdf8", modifiers: "Bold"))
                          ]
                      )
                  ],
              ),
          )
        '';
        "rmpc/config.ron".text = ''
          #![enable(implicit_some)]
          #![enable(unwrap_newtypes)]
          #![enable(unwrap_variant_newtypes)]
          (
              address: "${mpdAddress}",
              password: None,
              theme: Some("cat"),
              cache_dir: None,
              on_song_change: ["${lib.getExe song-change}"],
              volume_step: 5,
              max_fps: 30,
              scrolloff: 0,
              wrap_navigation: false,
              enable_mouse: true,
              status_update_interval_ms: 1000,
              select_current_song_on_change: true,
              cava: (
                  framerate: 30, // default 60
                  autosens: true, // default true
                  sensitivity: 80, // default 100
                  lower_cutoff_freq: 50, // not passed to cava if not provided
                  higher_cutoff_freq: 10000, // not passed to cava if not provided
                  input: (
                      method: Fifo,
                      source: "/tmp/mpd.fifo",
                      sample_rate: 44100,
                      channels: 2,
                      sample_bits: 16,
                  ),
                  smoothing: (
                      noise_reduction: 35, // default 77
                      monstercat: false, // default false
                      waves: true, // default false
                  ),
                  // this is a list of floating point numbers thats directly passed to cava
                  // they are passed in order that they are defined
                  eq: []
              ),
              album_art: (
                  method: Auto,
                  max_size_px: (width: 1200, height: 1200),
                  disabled_protocols: ["http://", "https://"],
                  vertical_align: Center,
                  horizontal_align: Center,
              ),
              keybinds: (
                  global: {
                      ":":       CommandMode,
                      ",":       VolumeDown,
                      "s":       Stop,
                      ".":       VolumeUp,
                      "<Tab>":   NextTab,
                      "<S-Tab>": PreviousTab,
                      "1":       SwitchToTab("Queue"),
                      "2":       SwitchToTab("Directories"),
                      "3":       SwitchToTab("Artists"),
                      "4":       SwitchToTab("Album Artists"),
                      "5":       SwitchToTab("Albums"),
                      "6":       SwitchToTab("Playlists"),
                      "7":       SwitchToTab("Search"),
                      "q":       Quit,
                      ">":       NextTrack,
                      "p":       TogglePause,
                      "<":       PreviousTrack,
                      "f":       SeekForward,
                      "z":       ToggleRepeat,
                      "x":       ToggleRandom,
                      "c":       ToggleConsume,
                      "v":       ToggleSingle,
                      "b":       SeekBack,
                      "~":       ShowHelp,
                      "I":       ShowCurrentSongInfo,
                      "O":       ShowOutputs,
                      "P":       ShowDecoders,
                  },
                  navigation: {
                      "k":         Up,
                      "j":         Down,
                      "h":         Left,
                      "l":         Right,
                      "<Up>":      Up,
                      "<Down>":    Down,
                      "<Left>":    Left,
                      "<Right>":   Right,
                      "<C-k>":     PaneUp,
                      "<C-j>":     PaneDown,
                      "<C-h>":     PaneLeft,
                      "<C-l>":     PaneRight,
                      "<C-u>":     UpHalf,
                      "N":         PreviousResult,
                      "a":         Add,
                      "A":         AddAll,
                      "r":         Rename,
                      "n":         NextResult,
                      "g":         Top,
                      "<Space>":   Select,
                      "<C-Space>": InvertSelection,
                      "G":         Bottom,
                      "<CR>":      Confirm,
                      "i":         FocusInput,
                      "J":         MoveDown,
                      "<C-d>":     DownHalf,
                      "/":         EnterSearch,
                      "<C-c>":     Close,
                      "<Esc>":     Close,
                      "K":         MoveUp,
                      "D":         Delete,
                  },
                  queue: {
                      "D":       DeleteAll,
                      "<CR>":    Play,
                      "<C-s>":   Save,
                      "a":       AddToPlaylist,
                      "d":       Delete,
                      "i":       ShowInfo,
                      "C":       JumpToCurrent,
                  },
              ),
              search: (
                  case_sensitive: false,
                  mode: Contains,
                  tags: [
                      (value: "any",         label: "Any Tag"),
                      (value: "artist",      label: "Artist"),
                      (value: "album",       label: "Album"),
                      (value: "albumartist", label: "Album Artist"),
                      (value: "title",       label: "Title"),
                      (value: "filename",    label: "Filename"),
                      (value: "genre",       label: "Genre"),
                  ],
              ),
              artists: (
                  album_display_mode: SplitByDate,
                  album_sort_by: Date,
              ),
              tabs: [
                  (
                      name: "Queue",
                      pane: Split(
                        direction: Horizontal,
                        panes: [
                          (size: "40%", pane: Pane(AlbumArt)),
                          (size: "60%", pane: Split(
                            direction: Vertical,
                            panes: [
                              (size: "70%", pane: Pane(Queue)),
                              (size: "30%", pane: Pane(Cava)),
                            ],
                          )),
                        ],
                      ),
                  ),
                  (
                      name: "Directories",
                      pane: Pane(Directories),
                  ),
                  (
                      name: "Artists",
                      pane: Pane(Artists),
                  ),
                  (
                      name: "Album Artists",
                      pane: Pane(AlbumArtists),
                  ),
                  (
                      name: "Albums",
                      pane: Pane(Albums),
                  ),
                  (
                      name: "Playlists",
                      pane: Pane(Playlists),
                  ),
                  (
                      name: "Search",
                      pane: Pane(Search),
                  ),
              ],
          )
        '';
      };
    };
}

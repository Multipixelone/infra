{
  flake.modules.homeManager.base = {
    programs.fish.shellAliases = {
      ff = "fastfetch";
    };
    programs.fastfetch = {
      enable = true;
      settings = {
        logo = {
          type = "auto";
          padding = {
            top = 1;
            left = 4;
          };
          width = 10;
        };

        display = {
          separator = "  ";
          key = {
            width = 8;
            type = "string";
          };
          bar.char = {
            elapsed = "█";
            total = "░";
            width = 20;
          };
        };

        modules = [
          {
            type = "custom";
            format = "⊹₊⋆☁︎⋆⁺₊ finn@infra ⋆ .🌙⊹₊.";
            outputColor = "34";
          }
          "break"

          # Hardware
          {
            type = "custom";
            format = "  Hardware";
            outputColor = "1;33";
          }
          {
            type = "host";
            key = " 󰌢 PC";
            keyColor = "red";
          }
          {
            type = "cpu";
            key = "  CPU";
            showPeCoreCount = true;
            keyColor = "red";
          }
          {
            type = "gpu";
            key = " 󰢮 GPU";
            keyColor = "red";
          }
          {
            type = "memory";
            key = "  MEM";
            keyColor = "red";
            percent = {
              type = 10;
            };
          }
          {
            type = "disk";
            key = " 󰋊 Disk ({2})";
            keyColor = "red";
            folders = "/nix:/home:/media/Data";
            percent = {
              type = 10;
            };
          }
          "break"

          # Software
          {
            type = "custom";
            format = " 󱄅 Software";
            outputColor = "1;33";
          }
          {
            type = "os";
            key = " 󱄅 OS";
            keyColor = "green";
          }
          {
            type = "kernel";
            key = "  Kernel";
            keyColor = "green";
          }
          {
            type = "packages";
            key = "  Pkgs";
            keyColor = "green";
            format = "{} (nix)";
          }
          {
            type = "terminal";
            key = "  Term";
            keyColor = "green";
          }
          {
            type = "shell";
            key = "  Shell";
            keyColor = "green";
          }
          "break"

          # Desktop
          {
            type = "custom";
            format = "  Desktop";
            outputColor = "1;33";
          }
          {
            type = "de";
            key = "  DE";
            keyColor = "blue";
          }
          {
            type = "wm";
            key = "  WM";
            keyColor = "blue";
          }
          {
            type = "wmtheme";
            key = " 󰉼 Theme";
            keyColor = "blue";
          }
          {
            type = "font";
            key = "  Font";
            keyColor = "blue";
          }
          {
            type = "cursor";
            key = " 󰆿 Cursor";
            keyColor = "blue";
          }
          "break"

          # Network
          {
            type = "custom";
            format = "  Network";
            outputColor = "1;33";
          }
          {
            type = "publicip";
            key = " 󰩟 Pub IP";
            keyColor = "blue";
            format = "{1} - {2}";
          }
          {
            type = "localip";
            key = " 󰈀 Loc IP";
            keyColor = "blue";
            format = "{1} - {3}";
            showMac = true;
          }
          {
            type = "wifi";
            key = " 󰖩 Wi-Fi";
            keyColor = "blue";
            format = "{4} - {7} - {13} GHz - {6} - {10}";
          }
          {
            type = "bluetooth";
            key = " 󰂯 BT Dev";
            keyColor = "blue";
            format = "{1} - {4}";
          }
          {
            type = "bluetoothradio";
            key = " 󰂱 BT Ver";
            keyColor = "blue";
            format = "{5}";
          }
          "break"

          # Misc
          {
            type = "custom";
            format = " 󰣐 Misc";
            outputColor = "1;33";
          }
          {
            type = "uptime";
            key = " 󰔚 Up";
            keyColor = "magenta";
          }
          {
            type = "media";
            key = " 󰝚 Music";
            keyColor = "magenta";
            format = "{1} - {4}";
          }
          {
            type = "datetime";
            key = " 󰃭 Date";
            keyColor = "magenta";
            format = "{3}/{11}/{1} - {14}:{18} {22}";
          }
          "break"
          {
            type = "custom";
            format = "  A star can only truly be seen in the darkness...";
            outputColor = "36";
          }
          "break"

          {
            type = "colors";
            paddingLeft = 20;
            symbol = "circle";
          }
          "break"
        ];
      };
    };
  };
}

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
            width = 16;
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
            format = "   Hardware";
            outputColor = "34";
          }
          {
            type = "host";
            key = "  󰌢 PC";
            keyColor = "36";
          }
          {
            type = "cpu";
            key = "   CPU";
            showPeCoreCount = true;
            keyColor = "36";
          }
          {
            type = "gpu";
            key = "  󰢮 GPU";
            keyColor = "36";
          }
          {
            type = "memory";
            key = "   MEM";
            keyColor = "36";
            percent = {
              type = 10;
            };
          }
          {
            type = "disk";
            key = "  󰋊 Disk ({2})";
            keyColor = "36";
            folders = "/nix:/home:/media/Data";
            percent = {
              type = 10;
            };
          }
          "break"

          # Software
          {
            type = "custom";
            format = "   Software";
            outputColor = "34";
          }
          {
            type = "os";
            key = "  󱄅 OS";
            keyColor = "36";
          }
          {
            type = "kernel";
            key = "   Kernel";
            keyColor = "36";
          }
          {
            type = "packages";
            key = "   Pkgs";
            keyColor = "36";
            format = "{} (nix)";
          }
          {
            type = "terminal";
            key = "   Term";
            keyColor = "36";
          }
          {
            type = "shell";
            key = "   Shell";
            keyColor = "36";
          }
          "break"

          # # Desktop
          # {
          #   type = "custom";
          #   format = " 󰇄  Desktop";
          #   outputColor = "34";
          # }
          # {
          #   type = "de";
          #   key = "   DE";
          #   keyColor = "36";
          # }
          # {
          #   type = "wm";
          #   key = "   WM";
          #   keyColor = "36";
          # }
          # {
          #   type = "wmtheme";
          #   key = "  󰉼 Theme";
          #   keyColor = "36";
          # }
          # {
          #   type = "font";
          #   key = "   Font";
          #   keyColor = "36";
          # }
          # {
          #   type = "cursor";
          #   key = "  󰆿 Cursor";
          #   keyColor = "36";
          # }
          # "break"

          # # Network
          # {
          #   type = "custom";
          #   format = " 󰤨  Network";
          #   outputColor = "34";
          # }
          # {
          #   type = "publicip";
          #   key = "  󰩟 Pub IP";
          #   keyColor = "36";
          #   format = "{1} - {2}";
          # }
          # {
          #   type = "localip";
          #   key = "  󰈀 Loc IP";
          #   keyColor = "36";
          #   format = "{1} - {3}";
          #   showMac = false;
          # }
          # {
          #   type = "wifi";
          #   key = "  󰖩 Wi-Fi";
          #   keyColor = "36";
          #   format = "{ssid}";
          # }
          # {
          #   type = "bluetooth";
          #   key = "  󰂯 BT Dev";
          #   keyColor = "36";
          #   format = "{1} - {4}";
          # }
          # {
          #   type = "bluetoothradio";
          #   key = "  󰂱 BT Ver";
          #   keyColor = "36";
          #   format = "{5}";
          # }
          # "break"

          # Misc
          {
            type = "custom";
            format = " 󰣐  Misc";
            outputColor = "34";
          }
          {
            type = "uptime";
            key = "  󰔚 Uptime";
            keyColor = "36";
          }
          {
            type = "media";
            key = "  󰝚 Music";
            keyColor = "36";
            format = "{1} - {4}";
          }
          {
            type = "datetime";
            key = "  󰃭 Date";
            keyColor = "36";
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
            paddingLeft = 18;
            symbol = "circle";
          }
          "break"
        ];
      };
    };
  };
}

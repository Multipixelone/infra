{
  caches = [
    {
      url = "https://yazi.cachix.org";
      key = "yazi.cachix.org-1:Dcdz63NZKfvUCbDGngQDAZq6kOroIrFoyO064uvLh8k=";
    }
  ];
  flake.modules.homeManager.base =
    { lib, pkgs, ... }:
    {
      programs.yazi = {
        enable = true;
        shellWrapperName = "y";
        settings = {
          manager = {
            linemode = "size";
            sort_by = "natural";
            sort_dir_first = true;
          };
        };
        keymap = {
          manager.prepend_keymap =
            [
              {
                on = [ "<C-u>" ];
                run = ''
                  shell '0x0 "$0"' --confirm
                '';
              }
              {
                on = [ "<C-s>" ];
                run = "shell '$SHELL' --block --confirm";
                desc = "Open shell here";
              }
            ]
            # ripdrag (drag-and-drop) and wl-clipboard are Wayland/Linux-only.
            ++ lib.optionals pkgs.stdenv.isLinux [
              {
                on = [ "<C-n>" ];
                run = ''
                  shell '${lib.getExe pkgs.ripdrag} "$@" -x -n 2>/dev/null &' --confirm
                '';
                desc = "Drag and drop item";
              }
              {
                on = [ "y" ];
                run = [
                  "yank"
                  ''
                    shell --confirm 'for path in "$@"; do echo "file://$path"; done | ${lib.getExe' pkgs.wl-clipboard "wl-copy"} -t text/uri-list'
                  ''
                ];
              }
            ]
            # macOS: yank file paths to the system clipboard via pbcopy.
            ++ lib.optionals pkgs.stdenv.isDarwin [
              {
                on = [ "y" ];
                run = [
                  "yank"
                  ''
                    shell --confirm 'for path in "$@"; do echo "file://$path"; done | pbcopy'
                  ''
                ];
              }
            ];
        };
      };
    };
}

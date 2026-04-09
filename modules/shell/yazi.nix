{
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
          manager.prepend_keymap = [
            {
              on = [ "<C-n>" ];
              run = ''
                shell '${lib.getExe pkgs.ripdrag} "$@" -x -n 2>/dev/null &' --confirm
              '';
              desc = "Drag and drop item";
            }
            {
              on = [ "<C-u>" ];
              run = ''
                shell '0x0 "$0"' --confirm
              '';
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
            {
              on = [ "<C-s>" ];
              run = "shell '$SHELL' --block --confirm";
              desc = "Open shell here";
            }
          ];
        };
      };
    };
}

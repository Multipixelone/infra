{ pkgs }:
pkgs.writeShellApplication {
  name = "beets-backfill-mode-lock";
  runtimeInputs = [ pkgs.util-linux ];
  text = builtins.readFile ./beets-backfill-mode-lock.sh;
}

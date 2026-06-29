{
  flake.modules.homeManager.base =
    { pkgs, lib, ... }:
    {
      home.packages =
        (with pkgs; [
          ani-cli
          ffmpeg
          gifski
        ])
        # imv is a Wayland/X11 image viewer — Linux-only.
        ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.imv ];
    };
}

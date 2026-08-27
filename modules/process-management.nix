{
  flake.modules.homeManager.base =
    { pkgs, lib, ... }:
    {
      home.packages =
        (with pkgs; [
          lsof
          procs
          watchexec
        ])
        ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [ pkgs.psmisc ];

      programs.bottom = {
        enable = true;
        settings = {
          rate = 400;
        };
      };
    };
}

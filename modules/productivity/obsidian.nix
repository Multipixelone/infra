{
  nixpkgs.config.allowUnfreePackages = [ "obsidian" ];
  flake.modules.homeManager.gui =
    { pkgs, lib, ... }:
    {
      home.packages = [
        pkgs.obsidian
      ];
      systemd.user.services.obsidian = {
        Unit = {
          Description = "Obsidian always-on (CLI + REST API)";
          After = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
          ConditionEnvironment = "WAYLAND_DISPLAY";
        };
        Install.WantedBy = [ "graphical-session.target" ];
        Service = {
          Type = "simple";
          ExecStart = lib.getExe pkgs.obsidian;
          Restart = "always";
          RestartSec = 10;
        };
      };
    };
}

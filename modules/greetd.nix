{ lib, ... }:
{
  flake.modules.nixos.pc =
    {
      pkgs,
      config,
      ...
    }:
    let
      # TODO run tuigreet inside of kmscon
      # kmscon = "${pkgs.kmscon}/libexec/kmscon/kmscon";
      tuigreet = lib.getExe pkgs.tuigreet;
      uwsm = lib.getExe config.programs.uwsm.package;
      hypr-cmd = "${uwsm} start -e -D Hyprland hyprland-uwsm.desktop"; # hyprland = lib.getExe' config.programs.hyprland.package "Hyprland";
      # hyprland-session = "${config.programs.hyprland.package}/share/wayland-sessions";
    in
    {
      # required for keyring to unlock on boot
      security.pam.services.greetd.enableGnomeKeyring = true;
      programs.uwsm.waylandCompositors.hyprland = {
        binPath = lib.mkForce "/run/current-system/sw/bin/start-hyprland";
        prettyName = "Hyprland";
      };
      services.desktopManager.plasma6.enable = true;
      services = {
        # seatd.enable = true;
        # kmscon = {
        #   enable = true;
        #   extraConfig = "font-size=24";
        #   fonts = [
        #     {
        #       name = "PragmataPro Liga";
        #       package = pkgs.callPackage ../../pkgs/pragmata {};
        #     }
        #   ];
        # };
        greetd =
          let
            session = {
              command = hypr-cmd;
              user = "tunnel";
            };
          in
          {
            enable = true;
            settings = lib.mkMerge [
              (lib.mkIf (config.networking.hostName == "link") {
                initial_session = session;
                default_session = session;
              })
              (lib.mkIf (config.networking.hostName == "zelda") {
                default_session = {
                  command = "${tuigreet} --greeting \"hi finn :)\" --time --remember --remember-session --sessions /run/current-system/sw/share/wayland-sessions";
                  user = "greeter";
                };
              })
            ];
          };
      };
      # this is a life saver.
      # literally no documentation about this anywhere.
      # might be good to write about this...
      # https://www.reddit.com/r/NixOS/comments/u0cdpi/tuigreet_with_xmonad_how/
      systemd.services.greetd.serviceConfig = {
        Type = "idle";
        StandardInput = "tty";
        StandardOutput = "tty";
        StandardError = "journal"; # Without this errors will spam on screen
        # Without these bootlogs will spam on screen
        TTYReset = true;
        TTYVHangup = true;
        TTYVTDisallocate = true;
      };
    };
}

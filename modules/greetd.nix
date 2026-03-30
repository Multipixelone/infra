{ lib, withSystem, ... }:
{
  flake.modules.nixos.pc =
    {
      pkgs,
      config,
      ...
    }:
    let
      cage = lib.getExe pkgs.cage;
      foot = lib.getExe (
        withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.foot)
      );
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
      services = {
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
                  command = "${cage} -s -- ${foot} -o 'font=PragmataPro Mono Liga:size=16' -e ${tuigreet} --greeting \"hi finn :)\" --time --remember --remember-session --cmd '${hypr-cmd}'";
                  user = "greeter";
                };
              })
            ];
          };
      };
      # https://www.reddit.com/r/NixOS/comments/u0cdpi/tuigreet_with_xmonad_how/
      systemd.services.greetd.serviceConfig = lib.mkMerge [
        {
          Type = "idle";
          StandardError = "journal";
        }
        # TTY settings are only needed for direct VT greeters (link autologin).
        # cage manages its own display, so these interfere with VT handoff to Hyprland.
        (lib.mkIf (config.networking.hostName == "link") {
          StandardInput = "tty";
          StandardOutput = "tty";
          TTYReset = true;
          TTYVHangup = true;
          TTYVTDisallocate = true;
        })
      ];
    };
}

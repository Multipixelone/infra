# https://github.com/fufexan/dotfiles/blob/483680e121b73db8ed24173ac9adbcc718cbbc6e/system/programs/gamemode.nix
{
  lib,
  withSystem,
  inputs,
  config,
  ...
}:
let
  username = config.flake.meta.owner.username;
in
{
  configurations.nixos.link.module =
    {
      pkgs,
      config,
      ...
    }:
    let
      hyprctl-instance = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.hyprctl-instance
      );
      programs = [
        hyprctl-instance
        config.programs.hyprland.package
        pkgs.systemd
        pkgs.gawk
        pkgs.coreutils
        pkgs.curl
        pkgs.libnotify
        pkgs.mako
      ];
      startscript = pkgs.writeShellApplication {
        name = "gamemode-start";
        runtimeInputs = programs;
        text = ''
          SECRET=$(cat "${config.age.secrets."syncthing".path}")
          HYPRLAND_INSTANCE_SIGNATURE=$(hyprctl-instance)
          systemctl stop podman-nicotine
          export HYPRLAND_INSTANCE_SIGNATURE
          # ledfx change scene (disabled temporarily)
          # curl -X 'PUT' 'http://link.bun-hexatonic.ts.net:8888/api/scenes' -H 'Content-Type: application/json' -d '{"id": "gaming-mode", "action": "activate"}'
          # send request to pause syncthing while game is playing
          curl -X POST -H "X-API-Key: $SECRET" http://localhost:8384/rest/system/pause
          hyprctl --batch 'keyword animations:enabled 0; keyword decoration:drop_shadow 0; keyword general:gaps_in 0; keyword general:gaps_out 0; keyword general:border_size 1; keyword decoration:rounding 0'
          notify-send -a 'Gamemode' 'Optimizations activated'
          makoctl mode -a dnd
        '';
      };
      endscript = pkgs.writeShellApplication {
        name = "gamemode-end";
        runtimeInputs = programs;
        text = ''
          SECRET=$(cat "${config.age.secrets."syncthing".path}")
          HYPRLAND_INSTANCE_SIGNATURE=$(hyprctl-instance)
          export HYPRLAND_INSTANCE_SIGNATURE
          systemctl start podman-nicotine
          curl -X POST -H "X-API-Key: $SECRET" http://localhost:8384/rest/system/resume
          # curl -X 'PUT' 'http://link.bun-hexatonic.ts.net:8888/api/scenes' -H 'Content-Type: application/json' -d '{"id": "main-purple", "action": "activate"}'
          hyprctl --batch 'keyword animations:enabled 1; keyword decoration:drop_shadow 1; keyword general:gaps_in 5; keyword general:gaps_out 5; keyword general:border_size 3; keyword decoration:rounding 6'
          makoctl mode -r dnd
          notify-send -a 'Gamemode' 'Optimizations deactivated'
        '';
      };
    in
    {
      age.secrets = {
        "syncthing" = {
          file = "${inputs.secrets}/media/syncthing.age";
          mode = "400";
          owner = "tunnel";
          group = "users";
        };
      };
      users.extraGroups.gamemode.members = [ username ];
      programs = {
        gamescope = {
          enable = true;
          package = pkgs.gamescope;
          # capSysNice = true;
          args = [
            "--rt"
            "--expose-wayland"
          ];
        };
        gamemode = {
          enable = true;
          enableRenice = true;
          settings = {
            general = {
              softrealtime = "auto";
              renice = 15;
              inhibit_screensaver = 0;
            };
            gpu = {
              apply_gpu_optimisations = "accept-responsibility";
              gpu_device = 1;
              amd_performance_level = "high";
            };
            custom = {
              start = lib.getExe startscript;
              end = lib.getExe endscript;
            };
          };
        };
      };
      security.wrappers = {
        gamemode = {
          owner = "root";
          group = "root";
          source = "${lib.getExe' pkgs.gamemode "gamemoderun"}";
          capabilities = "cap_sys_ptrace,cap_sys_nice+pie";
        };
      };
    };
}

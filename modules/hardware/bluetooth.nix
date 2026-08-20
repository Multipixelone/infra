{ lib, ... }:
{
  flake.modules = {
    nixos.pc = {
      services.blueman.enable = true;
      hardware.bluetooth = {
        enable = true;
        powerOnBoot = true;
        disabledPlugins = [ "sap" ];
        settings = {
          General = {
            FastConnectable = "true";
            JustWorksRepairing = "always";
            MultiProfile = "multiple";
            Enable = "Source,Sink,Media,Socket";
          };
        };
      };
    };
    homeManager.gui =
      let
        headphones = "BC:87:FA:27:F5:4C";
        bc = "bluetoothctl connect ${headphones}";
        bd = "bluetoothctl disconnect ${headphones}";
      in
      {
        programs.fish.shellAbbrs = {
          hpc = "${bc}";
          hpd = "${bd}";
        };
        wayland.windowManager.hyprland.settings.bind = [
          {
            _args = [
              "CTRL + XF86AudioRaiseVolume"
              (lib.generators.mkLuaInline ''hl.dsp.exec_cmd("${bc}")'')
            ];
          }
          {
            _args = [
              "CTRL + XF86AudioLowerVolume"
              (lib.generators.mkLuaInline ''hl.dsp.exec_cmd("${bd}")'')
            ];
          }
        ];
      };
  };
}

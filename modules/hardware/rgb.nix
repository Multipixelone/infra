{ config, lib, ... }:
{
  flake.modules.nixos.gaming = {
    users.extraGroups.i2c.members = [ config.flake.meta.owner.username ];
    programs.coolercontrol.enable = true;
    hardware.i2c.enable = true;
    boot.kernelParams = [ "acpi_enforce_resources=lax" ];
    # hardware.openrazer.enable = true;
    services.hardware.openrgb = {
      enable = true;
    };
  };

  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      cfg = config.link.coolerArgb;
      settings = pkgs.writeText "link-cooler-argb.json" (
        builtins.toJSON {
          controller = "X570 AORUS ELITE WIFI";
          zone = "D_LED1 Bottom";
          led_count = cfg.ledCount;
          ledfx_device = "x570-aorus-elite-wifi";
          virtual = "top-front-fan";
          port = config.services.hardware.openrgb.server.port;
        }
      );
      python = pkgs.python3.withPackages (ps: [
        ps.openrgb-python
        ps.tomlkit
      ]);
      # Keep Python imports together in the store; every executable entrypoint
      # is a writeShellApplication, with no standalone shell script.
      sources = pkgs.runCommand "link-rgb-config-sources" { } ''
        mkdir -p "$out"
        cp ${../../lib/link-argb-config.py} "$out/link_argb_config.py"
        cp ${../../lib/link-cooling-config.py} "$out/link_cooling_config.py"
      '';
      helper = pkgs.writeShellApplication {
        name = "link-argb-config";
        text = ''
          exec ${lib.getExe python} ${sources}/link_argb_config.py \
            --settings ${settings} "$@"
        '';
      };
    in
    {
      options.link.coolerArgb = {
        package = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          internal = true;
          default = helper;
          description = "Packaged cooler ARGB configuration helper.";
        };
        ledCount = lib.mkOption {
          type = lib.types.ints.between 1 512;
          default = 6;
          description = "Logical D_LED1 LEDs: splitter-connected cooler fans mirror six pixels.";
        };
      };
      config = {
        environment.systemPackages = [ helper ];
        # OpenRGB's service installs its package udev rules, including 048d:8297
        # with uaccess. LedFx communicates over the existing localhost SDK.
        home-manager.users.tunnel = {
          systemd.user.services.ledfx.Service = {
            ExecStartPre = [ "${lib.getExe helper} --config %h/.ledfx/config.json" ];
            TimeoutStartSec = 120;
          };
        };
      };
    };
}

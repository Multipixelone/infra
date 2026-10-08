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
      rgb = config.link.ledfxOpenrgb;
      settings = pkgs.writeText "link-ledfx-openrgb.json" (
        builtins.toJSON {
          devices = rgb.devices;
          virtuals = rgb.virtuals;
          cooler = {
            device = "x570-aorus-elite-wifi";
            virtual = "top-front-fan";
            zoneNames = [
              "D_LED1 Bottom"
              "D_LED1"
            ];
            ledCount = cfg.ledCount;
          };
          port = config.services.hardware.openrgb.server.port;
        }
      );
      python = pkgs.python3.withPackages (ps: [ ps.openrgb-python ]);
      # Keep Python imports together in the store; every executable entrypoint
      # is a writeShellApplication, with no standalone shell script.
      sources = pkgs.runCommand "link-rgb-config-sources" { } ''
        mkdir -p "$out"
        cp ${../../lib/link-argb-config.py} "$out/link_argb_config.py"
      '';
      helper = pkgs.writeShellApplication {
        name = "link-argb-config";
        text = ''
          exec ${lib.getExe python} ${sources}/link_argb_config.py \
            --settings ${settings} "$@"
        '';
      };
      matchType = lib.types.submodule {
        options = {
          name = lib.mkOption {
            type = lib.types.str;
            description = "Exact OpenRGB controller name.";
          };
          vendor = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional exact SDK vendor.";
          };
          serial = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Optional exact hardware serial; preferred for HID devices.";
          };
          location = lib.mkOption {
            type = lib.types.nullOr (
              lib.types.submodule {
                options = {
                  bus = lib.mkOption {
                    type = lib.types.str;
                    description = "I2C bus description, excluding /dev/i2c-N.";
                  };
                  address = lib.mkOption {
                    type = lib.types.strMatching "0x[0-9a-f]{2}";
                    description = "Lowercase hexadecimal I2C address.";
                  };
                };
              }
            );
            default = null;
            description = "Optional stable I2C bus and address.";
          };
          zoneSignature = lib.mkOption {
            type = lib.types.nullOr (lib.types.attrsOf lib.types.ints.unsigned);
            default = null;
            description = "Optional exact zone-name to LED-count signature for identity matching.";
          };
        };
      };
      deviceType = lib.types.submodule {
        options = {
          match = lib.mkOption {
            type = matchType;
            description = "Stable OpenRGB identity; never a numeric index.";
          };
          pixelCount = lib.mkOption {
            type = lib.types.ints.positive;
            description = "Expected controller LED count after the cooler resize.";
          };
          optional = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "A disconnected device logs at info level and does not delay startup.";
          };
        };
      };
      segmentType = lib.types.submodule {
        options = {
          device = lib.mkOption {
            type = lib.types.str;
            description = "Existing LedFx device id.";
          };
          start = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.unsigned;
            default = null;
            description = "Inclusive first device LED for a fixed range.";
          };
          end = lib.mkOption {
            type = lib.types.nullOr lib.types.ints.unsigned;
            default = null;
            description = "Inclusive last device LED for a fixed range.";
          };
          zoneNames = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Whole-zone selection: exactly one of these names must exist.";
          };
          reverse = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Reverse this segment's pixel order.";
          };
        };
      };
      segment = device: start: end: reverse: {
        inherit
          device
          start
          end
          reverse
          ;
      };
      zone = device: zoneNames: { inherit device zoneNames; };
      ram = address: {
        match = {
          name = "Corsair Vengeance RGB Pro DDR4";
          vendor = "Corsair";
          location = {
            bus = "SMBus PIIX4 adapter port 0 at 0b00";
            inherit address;
          };
        };
        pixelCount = 10;
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
          default = 9;
          description = "Logical D_LED1 LEDs: splitter-connected cooler fans mirror nine pixels.";
        };
      };
      options.link.ledfxOpenrgb = {
        devices = lib.mkOption {
          type = lib.types.attrsOf deviceType;
          default = { };
          description = "LedFx OpenRGB devices keyed by existing LedFx id.";
        };
        virtuals = lib.mkOption {
          type = lib.types.attrsOf (lib.types.listOf segmentType);
          default = { };
          description = "Owned segment layouts keyed by existing LedFx virtual id.";
        };
        settingsFile = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          internal = true;
          default = settings;
          description = "Generated settings for the existing RGB helper.";
        };
      };
      config = {
        assertions = lib.flatten (
          lib.mapAttrsToList (
            virtual: segments:
            map (entry: {
              assertion =
                if entry.zoneNames != [ ] then
                  entry.start == null && entry.end == null && builtins.hasAttr entry.device rgb.devices
                else
                  entry.start != null && entry.end != null && entry.start <= entry.end;
              message = "LedFx virtual ${virtual}: use either a valid fixed range or zoneNames on a declared OpenRGB device.";
            }) segments
          ) rgb.virtuals
        );
        link.ledfxOpenrgb.devices = lib.mapAttrsRecursive (_: lib.mkDefault) {
          corsair-vengeance-pro-rgb = ram "0x58";
          corsair-vengeance-pro-rgb-1 = ram "0x59";
          corsair-vengeance-pro-rgb-2 = ram "0x5a";
          corsair-vengeance-pro-rgb-3 = ram "0x5b";
          gpu = {
            match = {
              name = "ASUS TUF Radeon RX 7800 XT Gaming OC";
              vendor = "ASUS";
              location = {
                bus = "AMDGPU DM i2c OEM bus";
                address = "0x67";
              };
            };
            pixelCount = 4;
          };
          x570-aorus-elite-wifi = {
            match = {
              name = "X570 AORUS ELITE WIFI";
              vendor = "Gigabyte";
              serial = "0x82970100";
            };
            pixelCount = cfg.ledCount + 4;
          };
          nzxt-smart-device-v2 = {
            match = {
              name = "NZXT Smart Device V2";
              vendor = "NZXT";
              serial = "00000000001A";
            };
            pixelCount = 34;
          };
          mk750 = {
            match.name = "MK750";
            pixelCount = 127;
            optional = true;
          };
          razer-mouse-bungee-v3-chroma = {
            match.name = "Razer Mouse Bungee V3 Chroma";
            pixelCount = 8;
            optional = true;
          };
          tunable-rgb-gaming-mouse-g502 = {
            match.name = "Tunable RGB Gaming Mouse G502";
            pixelCount = 2;
            optional = true;
          };
        };
        link.ledfxOpenrgb.virtuals = lib.mapAttrs (_: lib.mkDefault) {
          corsair-vengeance-pro-rgb = [
            (segment "corsair-vengeance-pro-rgb" 0 9 false)
          ];
          corsair-vengeance-pro-rgb-1 = [
            (segment "corsair-vengeance-pro-rgb-1" 0 9 false)
          ];
          corsair-vengeance-pro-rgb-2 = [
            (segment "corsair-vengeance-pro-rgb-2" 0 9 false)
          ];
          corsair-vengeance-pro-rgb-3 = [
            (segment "corsair-vengeance-pro-rgb-3" 0 9 false)
          ];
          mk750 = [
            (segment "mk750" 0 126 false)
          ];
          x570-aorus-elite-wifi = [
            (zone "x570-aorus-elite-wifi" [ "I/O Cover" ])
            (zone "x570-aorus-elite-wifi" [ "LED_CPU" ])
            (zone "x570-aorus-elite-wifi" [ "PCI-E Accent" ])
            (zone "x570-aorus-elite-wifi" [ "LED_C1/LED_C2" ])
          ];
          nzxt-smart-device-v2 = [
            (segment "nzxt-smart-device-v2" 0 33 false)
          ];
          razer-mouse-bungee-v3-chroma = [
            (segment "razer-mouse-bungee-v3-chroma" 0 7 false)
          ];
          tunable-rgb-gaming-mouse-g502 = [
            (segment "tunable-rgb-gaming-mouse-g502" 0 1 false)
          ];
          melt = [
            (segment "corsair-vengeance-pro-rgb" 0 9 true)
            (segment "corsair-vengeance-pro-rgb-2" 0 9 false)
            (segment "corsair-vengeance-pro-rgb-1" 0 9 true)
            (segment "corsair-vengeance-pro-rgb-3" 0 9 false)
            (segment "gpu" 0 3 false)
          ];
          nanoleaf = [
            (segment "nanoleaf" 0 4 false)
          ];
          back-fan = [
            (segment "nzxt-smart-device-v2" 0 9 false)
          ];
          top-front-fan = [
            (segment "nzxt-smart-device-v2" 10 17 true)
            (zone "x570-aorus-elite-wifi" [
              "D_LED1 Bottom"
              "D_LED1"
            ])
          ];
          bottom-front-fan = [
            (segment "nzxt-smart-device-v2" 18 25 true)
          ];
          back-fan-1 = [
            (segment "nzxt-smart-device-v2" 26 33 false)
          ];
          mk750-mask = [
            (segment "mk750-mask" 0 126 false)
          ];
          mk750-foreground = [
            (segment "mk750-foreground" 0 126 false)
          ];
          mk750-background = [
            (segment "mk750-background" 0 126 false)
          ];
          mouse = [
            (segment "tunable-rgb-gaming-mouse-g502" 0 1 false)
            (segment "razer-mouse-bungee-v3-chroma" 0 7 false)
            (segment "mk750" 0 126 false)
          ];
          bedroom = [
            (segment "bedroom" 0 49 false)
          ];
          room-lights = [
            (segment "nanoleaf" 0 4 true)
            (segment "bedroom" 0 132 true)
          ];
          gpu = [
            (segment "gpu" 0 3 false)
          ];
          melt-mask = [
            (segment "melt-mask" 0 43 false)
          ];
          melt-foreground = [
            (segment "melt-foreground" 0 43 false)
          ];
          melt-background = [
            (segment "melt-background" 0 43 false)
          ];
        };
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

{ inputs, ... }:
{
  flake-file.inputs = {
    millennium.url = "github:SteamClientHomebrew/Millennium?dir=packages/nix";

    steam-easygrid = {
      url = "github:luthor112/steam-easygrid";
      flake = false;
    };
  };
  nixpkgs = {
    config = {
      allowUnfreePackages = [
        "steam"
        "steam-unwrapped"
      ];
      packageOverrides = pkgs: {
        steam = inputs.millennium.packages.${pkgs.stdenv.hostPlatform.system}.default.override {
          extraProfile = ''
            # Fixes timezones
            unset TZ
          '';
          extraPkgs =
            pkgs: with pkgs; [
              libXcursor
              libXi
              libXinerama
              libXScrnSaver
              libpng
              libpulseaudio
              libvorbis
              stdenv.cc.cc.lib
              libkrb5
              keyutils
              # Steam VR
              procps
              usbutils
            ];
        };
      };
    };
  };
  flake.modules = {
    nixos.gaming =
      { pkgs, ... }:
      {
        imports = [
          inputs.nix-gaming.nixosModules.platformOptimizations
        ];
        hardware = {
          steam-hardware.enable = true;
          graphics = {
            # 32 bit support
            enable32Bit = true;
          };
        };

        programs.steam = {
          enable = true;
          localNetworkGameTransfers.openFirewall = true;
          platformOptimizations.enable = true;
          extraCompatPackages = with pkgs; [
            proton-ge-bin
          ];

        };
      };
    homeManager.gaming = {
      xdg = {
        dataFile."millenium/plugins/steam-easygrid".source = inputs.steam-easygrid;
        configFile."millenium/config.json".text = ''
          {
            "general": {
              "accentColor": "DEFAULT_ACCENT_COLOR",
              "checkForMillenniumUpdates": false,
              "checkForPluginAndThemeUpdates": false,
              "injectCSS": true,
              "injectJavascript": true,
              "millenniumUpdateChannel": "stable",
              "onMillenniumUpdate": 1,
              "shouldShowThemePluginUpdateNotifications": true
            },
            "misc": {
              "hasShownWelcomeModal": true
            },
            "notifications": {
              "showNotifications": true,
              "showPluginNotifications": true,
              "showUpdateNotifications": true
            },
            "plugins": {
              "enabledPlugins": [
                "steam-easygrid"
              ]
            },
            "themes": {
              "activeTheme": "default",
              "allowedScripts": true,
              "allowedStyles": true
            }
          }
        '';
      };
    };
  };
}

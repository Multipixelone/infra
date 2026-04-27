{
  flake-file.inputs.auto-cpufreq = {
    url = "github:AdnanHodzic/auto-cpufreq";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  flake.modules = {
    nixos.laptop = {
      imports = [
        # inputs.auto-cpufreq.nixosModules.default
      ];
      powerManagement = {
        enable = true;
        powertop.enable = true;
      };
      services.auto-cpufreq = {
        enable = true;
        settings = {
          charger = {
            governor = "performance";
            turbo = "auto";
          };
          battery = {
            governor = "powersave";
            turbo = "auto";
          };
        };
      };
      systemd.sleep.settings.Sleep = {
        HibernateDelaySec = "300s";
      };
      services = {
        thermald.enable = true;
        tlp.enable = false;
        logind.settings.Login = {
          HandleLidSwitch = "suspend-then-hibernate";
          HandleLidSwitchExernalPower = "suspend-then-hibernate";
        };
        # # testing undervolting
        # undervolt = {
        #   enable = true;
        #   # analogioOffset = -10;
        #   coreOffset = -10;
        #   # gpuOffset = -10;
        # };
      };
    };
  };
}

{
  flake-file.inputs.auto-cpufreq = {
    url = "github:AdnanHodzic/auto-cpufreq";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  flake.modules = {
    nixos.laptop = {
      imports = [
        # inputs.auto-cpufreq.nixosModules.default
        (
          { config, ... }:
          {
            assertions = [
              {
                assertion = config.systemd.sleep.settings.Sleep.HibernateDelaySec or null == "300s";
                message = "laptop sleep policy: ${config.networking.hostName} must keep the 300s hibernate delay";
              }
            ];
          }
        )
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

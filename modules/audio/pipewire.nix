{ inputs, config, ... }:
{
  flake-file.inputs.musnix.url = "github:musnix/musnix";

  flake.modules = {
    nixos.base = {
      users.extraGroups.audio.members = [ config.flake.meta.owner.username ];
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        wireplumber.enable = true;
        wireplumber.extraConfig = {
          "dualsense" = {
            "monitor.alsa.rules" = [
              {
                matches = [
                  {
                    "node.name" = "*Sony_Interactive_Entertainment_Wireless_Controller*";
                  }
                ];
                actions = {
                  update-props = {
                    "node.description" = "Wireless Controller";
                  };
                };
              }
            ];
          };
        };
      };
    };
    nixos.pc = {
      musnix.enable = true;
      security.rtkit.enable = true;
      services.pipewire = {
        pulse.enable = true;
        jack.enable = true;
        raopOpenFirewall = true;
        extraConfig.pipewire = {
          "10-airplay" = {
            "context.modules" = [
              {
                name = "libpipewire-module-raop-discover";
                # increase the buffer size if you get dropouts/glitches
                # args = {
                #   "raop.latency.ms" = 500;
                # };
              }
            ];
          };
        };
      };
      imports = [
        inputs.musnix.nixosModules.musnix
      ];
    };
    homeManager.base =
      { pkgs, ... }:
      {
        home.packages = with pkgs; [
          wiremix
          alsa-utils
        ];
      };
    homeManager.gui =
      { pkgs, ... }:
      {
        home.packages = with pkgs; [
          pwvucontrol
          crosspipe
        ];
      };
  };
}

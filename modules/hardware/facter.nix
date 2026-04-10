{ inputs, ... }:
{
  flake-file.inputs.nixos-facter-modules.url = "github:numtide/nixos-facter-modules";
  flake.modules = {
    nixos.base = {
      imports = [ inputs.nixos-facter-modules.nixosModules.facter ];
      facter.detected.dhcp.enable = false;
    };

    homeManager.base =
      { pkgs, ... }:
      {
        home.packages = with pkgs; [ nixos-facter ];
      };
  };
}

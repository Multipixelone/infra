{ inputs, withSystem, ... }:
{
  perSystem.wrappers.packages.noctalia-shell = true;
  flake.wrappers.noctalia-shell =
    { pkgs, wlib, ... }:
    {
      imports = [ wlib.wrapperModules.noctalia-shell ];
      package = inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default;
      inherit ((builtins.fromJSON (builtins.readFile ./noctalia.json))) settings;
    };
  flake.modules = {
    nixos.pc = {
      # battery widget needs this
      services.upower.enable = true;
    };
    homeManager.gui =
      { pkgs, ... }:
      {
        imports = [
          inputs.noctalia.homeModules.default
        ];
        programs.noctalia-shell = {
          enable = true;
          package = withSystem pkgs.stdenv.hostPlatform.system (
            psArgs: psArgs.config.packages.noctalia-shell
          );
        };
      };
  };
}

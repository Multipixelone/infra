{ inputs, ... }:
{
  flake.modules.homeManager.base = {
    imports = [
      inputs.qmd.homeModules.default
    ];
    programs.qmd = {
      enable = true;
    };
  };
}

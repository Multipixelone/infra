{ inputs, ... }:
{
  flake-file.inputs.qmd.url = "github:tobi/qmd";
  flake.modules.homeManager.base = {
    imports = [
      inputs.qmd.homeModules.default
    ];
    programs.qmd = {
      enable = true;
    };
  };
}

{
  inputs,
  ...
}:
{
  flake-file.inputs.catppuccin.url = "github:catppuccin/nix";

  flake.modules.homeManager.base = {
    imports = [
      inputs.catppuccin.homeModules.catppuccin
    ];
    catppuccin = {
      enable = true;
      flavor = "mocha";
      accent = "mauve";
      fish.enable = true;
      # these need IFD, so I disable
      bottom.enable = false;
      starship.enable = false;
      fzf.enable = false;
    };
  };
  flake.modules.homeManager.gui = {
    catppuccin = {
      mangohud.enable = false;
      lazygit.enable = true;
      # these need IFD, so I disable
      firefox.enable = false;
      anki.enable = false;
    };
  };
}

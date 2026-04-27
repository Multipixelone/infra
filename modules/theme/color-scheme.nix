{ inputs, lib, ... }:
let
  polyModule.stylix = lib.mkDefault {
    base16Scheme = "${inputs.tinted-schemes}/base16/catppuccin-mocha.yaml";
    polarity = "dark";
  };
in
{
  flake-file.inputs = {
    base16.url = "github:SenchoPens/base16.nix";
    tinted-schemes = {
      url = "github:tinted-theming/schemes";
      flake = false;
    };
  };

  flake.modules = {
    nixos.base = polyModule;
    homeManager.base = polyModule;
    nixOnDroid.base = polyModule;
    # https://github.com/danth/stylix/pull/415#issuecomment-2832398958
    #nixvim.base = polyModule;
  };
}

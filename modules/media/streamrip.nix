{
  lib,
  inputs,
  ...
}:
{
  flake-file.inputs.streamrip = {
    url = "github:mikelandzelo173/streamrip/feat/qobuz-login-fix";
    flake = false;
  };
  nixpkgs.overlays = [
    (_final: prev: {
      streamrip = prev.streamrip.overrideAttrs {
        src = inputs.streamrip;
        version = inputs.streamrip.rev;

        propagatedBuildInputs = prev.streamrip.propagatedBuildInputs ++ [
          prev.python3Packages.playwright
        ];
      };
    })
  ];
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    {
      home.packages = [
        pkgs.streamrip
      ];
      programs.fish.functions.rs = ''
        #!/bin/fish
        ${lib.getExe pkgs.streamrip} search qobuz album "$argv"
      '';
    };
}

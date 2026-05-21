{ inputs, config, ... }:
{
  flake-file.inputs.nixos-wsl = {
    url = "github:nix-community/NixOS-WSL/main";
    inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-compat.follows = "flake-compat";
    };
  };

  configurations.nixos.minish.module = {
    imports = (with config.flake.modules.nixos; [
      base
    ])
    ++ [ inputs.nixos-wsl.nixosModules.default ];
  };
}

{ config, lib, ... }:
{
  # The darwin host builds its own nixpkgs instance and bypasses the
  # flake-parts perSystem pkgs (modules/nixpkgs/instance.nix). Reuse the
  # repo's aggregated allow-lists so unfree/insecure packages stay declarative
  # and in sync with the NixOS hosts.
  configurations.darwin.hylia.module = {
    nixpkgs.config = {
      allowUnfreePredicate =
        pkg: builtins.elem (lib.getName pkg) config.nixpkgs.config.allowUnfreePackages;
      allowInsecurePredicate =
        pkg: builtins.elem (lib.getName pkg) config.nixpkgs.config.permittedInsecurePackages;
    };
  };
}

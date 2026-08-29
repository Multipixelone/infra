{
  inputs,
  config,
  lib,
  ...
}:
{
  flake-file.inputs.nixos-generators = {
    url = "github:nix-community/nixos-generators";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  configurations.nixos.iso.module = {
    hardware.graphics.enable = true;
    # installation-cd-graphical-calamares-plasma6.nix pulls in ZFS support
    # for installer media. zfs-kernel is currently marked broken against
    # this nixpkgs pin's kernel, which aborts eval outright - disable it the
    # same way upstream's own *-no-zfs.nix installer variants do, since this
    # repo has no ZFS hosts to install onto anyway.
    boot.supportedFilesystems.zfs = lib.mkForce false;
    imports = with config.flake.modules.nixos; [
      "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-plasma6.nix"
      "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/channel.nix"
      wifi
      pc
    ];
    environment.systemPackages =
      let
        pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
      in
      [
        # disko's package.nix still reads the deprecated stdenv.isDarwin alias.
        # This flake sets abort-on-warn, so that warning aborts the ISO build -
        # hand disko a stdenv where the alias is a plain bool instead.
        (inputs.disko.packages.x86_64-linux.disko.override {
          stdenv = pkgs.stdenv // {
            inherit (pkgs.stdenv.hostPlatform) isDarwin;
          };
        })
        pkgs.nixos-facter
      ];
  };
}

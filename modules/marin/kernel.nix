{
  # The fleet default (modules/boot/loader.nix) is linuxPackages_zen, but marin
  # needs the proprietary broadcom-sta (`wl`) driver for its BCM wifi card.
  # broadcom-sta is effectively unmaintained; nixpkgs' patch series only carries
  # it up to kernel 6.17, so it fails to compile against zen (7.1.x) and even the
  # mainline default (6.18). Pin marin to the 6.12 LTS kernel, which broadcom-sta
  # builds against, so the driver keeps working across flake bumps.
  configurations.nixos.marin.module =
    { pkgs, ... }:
    {
      # loader.nix sets this with mkDefault, so a plain assignment wins.
      boot.kernelPackages = pkgs.linuxPackages_6_12;
    };
}

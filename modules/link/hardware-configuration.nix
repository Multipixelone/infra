{
  lib,
  ...
}:
{
  configurations.nixos.link.module = {
    boot = {
      initrd = {
        supportedFilesystems = [ "btrfs" ];
        availableKernelModules = [
          "nvme"
          "xhci_pci"
          "usbhid"
          "usb_storage"
        ];
      };
      kernelParams = [
        "video=DP-1:2560x1440@240"
        "video=DP-3:1920x1200@60"
      ];
      loader = {
        efi = {
          efiSysMountPoint = "/boot/efi";
          canTouchEfiVariables = true;
        };
      };
    };

    nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

    swapDevices = [ { device = "/swap/swapfile"; } ];
    fileSystems = {
      "/boot/efi" = {
        device = "/dev/disk/by-uuid/9433-A195";
        fsType = "vfat";
      };
      "/swap" = {
        device = "/dev/disk/by-label/Linux";
        fsType = "btrfs";
        options = [ "subvol=@swap" ];
      };
      "/" = {
        device = "/dev/disk/by-label/Linux";
        fsType = "btrfs";
        options = [
          "subvol=/@nixos"
          "compress=zstd:3"
          "relatime"
          "ssd"
          "discard=async"
          "space_cache"
        ];
      };
      "/home" = {
        device = "/dev/disk/by-label/Linux";
        fsType = "btrfs";
        options = [
          "subvol=/@home"
          "compress=zstd:3"
          "relatime"
          "ssd"
          "discard=async"
          "space_cache"
        ];
      };
      # 2TB NVME Drive (Games & Nix Store)
      "/nix" = {
        device = "/dev/disk/by-label/TeraData";
        fsType = "btrfs";
        neededForBoot = true;
        options = [
          "subvol=/@nix"
          "compress=zstd:3"
          "noatime"
          "ssd"
          "discard=async"
          "space_cache=v2"
        ];
      };
      "/media/Games" = {
        device = "/dev/disk/by-label/TeraData";
        fsType = "btrfs";
        options = [
          "subvol=/@games"
          "compress=zstd:3"
          "relatime"
          "ssd"
          "discard=async"
          "space_cache=v2"
        ];
      };
      # Music Library on 4TB NVMe
      "/volume1/Media" = {
        device = "/dev/disk/by-label/4Tera";
        fsType = "btrfs";
        options = [
          "subvol=/@music"
          "compress=zstd:3"
          "relatime"
          "ssd"
          "discard=async"
          "space_cache=v2"
        ];
      };
      # Mount to old mountpoint for backwards compatability
      "/media/Data" = {
        device = "/dev/disk/by-label/4Tera";
        fsType = "btrfs";
        options = [
          "subvol=/@music"
          "compress=zstd:3"
          "relatime"
          "ssd"
          "discard=async"
          "space_cache=v2"
        ];
      };
      # HDD
      "/media/SlowData" = {
        device = "/dev/disk/by-label/SlowData";
        fsType = "btrfs";
        options = [
          "subvol=/"
          "compress=zstd:3"
          "noatime"
          "space_cache=v2"
          "autodefrag"
        ];
      };
    };
  };
}

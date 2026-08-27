{ lib, ... }:
{
  configurations.nixos.impa.module =
    { config, ... }:
    {
      options.impa.install.diskDevice = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/dev/disk/by-id/ata-DEVICE_FROM_INSTALLER_DISCOVERY";
        description = "Installer-supplied physical disk path. Intentionally unset until Impa hardware discovery.";
      };

      config = lib.mkIf (config.impa.install.diskDevice != null) {
        disko.devices.disk.impa = {
          type = "disk";
          device = config.impa.install.diskDevice;
          content = {
            type = "gpt";
            partitions = {
              ESP = {
                size = "1G";
                type = "EF00";
                content = {
                  type = "filesystem";
                  format = "vfat";
                  mountpoint = "/boot";
                  mountOptions = [ "umask=0077" ];
                };
              };
              root = {
                size = "100%";
                content = {
                  type = "btrfs";
                  extraArgs = [ "-f" ];
                  subvolumes = {
                    "@root" = {
                      mountpoint = "/";
                      mountOptions = [
                        "compress=zstd"
                        "noatime"
                      ];
                    };
                    "@home" = {
                      mountpoint = "/home";
                      mountOptions = [
                        "compress=zstd"
                        "noatime"
                      ];
                    };
                    "@nix" = {
                      mountpoint = "/nix";
                      mountOptions = [
                        "compress=zstd"
                        "noatime"
                      ];
                    };
                  };
                };
              };
            };
          };
        };
      };
    };
}

{
  lib,
  # config,
  ...
}:
# let
#   inherit (config.flake.modules.nixos) gaming;
# in
{
  nixpkgs.config.allowUnfreePackages = [
    "nvidia-x11"
    "nvidia-settings"
    "nvidia-persistenced"
  ];
  configurations.nixos.zelda.module =
    { pkgs, config, ... }:
    {
      specialisation.nvidia.configuration = {
        # imports = [ gaming ];
        system.nixos.tags = [ "nvidia" ];

        # Remove VFIO passthrough and VM-related boot config
        boot.kernelModules = lib.mkForce [
          "iwlwifi"
          "kvm-intel"
        ];
        boot.blacklistedKernelModules = lib.mkForce [ ];
        boot.extraModprobeConfig = lib.mkForce "";
        boot.extraModulePackages = lib.mkForce [ ];
        boot.kernelParams = lib.mkForce [
          "intel_iommu=on"
          "iommu=pt"
          "split_lock_detect=off"
          "resume_offset=213741148"
          "nvidia-drm.modeset=1"
          "nvidia-drm.fbdev=1"
        ];

        # NVIDIA driver
        services.xserver.videoDrivers = [ "nvidia" ];
        hardware.nvidia = {
          modesetting.enable = true;
          open = true;
          nvidiaSettings = true;
          prime = {
            sync.enable = true;
            intelBusId = "PCI:0@0:2:0";
            nvidiaBusId = "PCI:1@0:0:0";
          };
        };
      };
      services.logrotate.checkConfig = false;
      boot = {
        resumeDevice = "/dev/disk/by-uuid/576fdcd4-d642-4229-9073-90724eb72043";
        # use ram for /tmp
        tmp = {
          useTmpfs = true;
          tmpfsSize = "30%";
        };
        initrd = {
          systemd.enable = true;
          availableKernelModules = [
            "xhci_pci"
            "ahci"
            "nvme"
            "usb_storage"
            "sd_mod"
            "rtsx_pci_sdmmc"
          ];
          kernelModules = [ ];
        };
        kernelModules = [
          "iwlwifi"
          "kvm-intel"
          "vfio-pci"
        ];
        kernelParams = [
          "intel_iommu=on"
          "iommu=pt"
          # ignore split lock detections
          "split_lock_detect=off"
          # btrfs hibernate resume
          "resume_offset=213741148"
        ];
        blacklistedKernelModules = [
          "nouveau"
          "nvidiafb"
          "nvidia"
          "nvidia-uvm"
          "nvidia-drm"
          "nvidia-modeset"
        ];
        # options snd_hda_intel power_save=5
        # options iwlwifi power_save=1
        extraModprobeConfig = ''
          options vfio-pci ids=10de:2757,10de:22bb
        '';
        extraModulePackages = [ ];
        loader = {
          systemd-boot.enable = false;
          limine.extraEntries = ''
            /Windows 11
            	protocol: efi
            	path: boot():/EFI/Microsoft/Boot/bootmgfw.efi
          '';
          grub.enable = false;
          efi = {
            efiSysMountPoint = "/boot";
            canTouchEfiVariables = true;
          };
        };
      };
      # power management stuff
      # Syncthing
      services.syncthing = {
        enable = true;
        user = "tunnel";
        configDir = "/home/tunnel/.config/syncthing";
        overrideDevices = true;
        overrideFolders = true;
        settings = {
          devices = {
            "link" = {
              id = "XOMPLRL-64GMF4T-P4SQ4XN-GCG26C2-3BKWACO-4DSWVCW-BU755ZU-KOJUDQ2";
            };
            "alexandria" = {
              id = "RBYKQEM-33KIP3W-D6KE3OD-V66VRWA-O6HZMFD-PKBWCWI-FZF6JD7-IZGLHAK";
            };
            "deck" = {
              id = "WPTWVQC-SJIKJOM-6SXC474-A6AJXVA-CBS5WQB-SREKAIH-XP6YCHN-PGK7KQE";
            };
            "minish".id = "36AQOJE-HBX7O7L-M7C3UHJ-5SVQOZU-Y4ZOMVQ-ZRCXL77-MMQT2XK-6OYGXQR";
          };
          folders = {
            "transcoded-music" = {
              path = "/home/tunnel/Music/Library";
              devices = [ "link" ];
            };
            "playlists" = {
              path = "/home/tunnel/Music/Playlists";
              devices = [
                "link"
                "alexandria"
              ];
            };
            "multimc" = {
              path = "/home/tunnel/.local/share/PrismLauncher/instances/";
              devices = [
                "link"
                "alexandria"
                "deck"
                "minish"
              ];
            };
            "multimc-icons" = {
              path = "/home/tunnel/.local/share/PrismLauncher/icons/";
              devices = [
                "link"
                "alexandria"
                "deck"
                "minish"
              ];
            };
            "sakft-erofr" = {
              path = "/home/tunnel/Games/ship-of-harkinian";
              devices = [
                "link"
                "alexandria"
                "deck"
              ];
            };
            "singing" = {
              path = "/home/tunnel/Music/Singing";
              devices = [
                "link"
                "alexandria"
              ];
            };
            "screenshots" = {
              path = "/home/tunnel/Pictures/Screenshots";
              devices = [
                "link"
                "alexandria"
              ];
            };
            "qgis" = {
              path = "/home/tunnel/Documents/QGIS";
              devices = [
                "link"
                "alexandria"
              ];
            };
            "vintage-story" = {
              path = "/home/tunnel/Games/vintage-story";
              devices = [
                "link"
                "alexandria"
                "deck"
                "minish"
              ];
            };
            "tvhrc-cfaky" = {
              path = "/home/tunnel/.local/share/Steam/userdata/122579086/config/grid";
              devices = [
                "link"
                "deck"
                "alexandria"
              ];
            };
          };
        };
      };
      networking = {
        useDHCP = lib.mkDefault true;
        hostName = "zelda";
        wg-quick.interfaces.wg0 = {
          autostart = false;
          type = "amneziawg";
          address = [ "10.100.0.2/24" ];
          mtu = 1000;
          dns = [ "10.100.0.1" ];
          privateKeyFile = config.age.secrets."wireguard".path;
          extraOptions = {
            # Header obfuscation
            H1 = 3552562;
            H2 = 3289397;
            H3 = 7481934;
            H4 = 5765241;
            # Junk packets
            Jc = 5;
            Jmin = 50;
            Jmax = 500;
            # Packet size padding
            S1 = 71;
            S2 = 93;
            S3 = 47;
            S4 = 62;
          };
          peers = [
            {
              publicKey = "VsMThxcXgr5nNNDQ6rSKlQQ9T6rWkedULuTHE4/jA24=";
              presharedKeyFile = config.age.secrets."psk".path;
              allowedIPs = [ "0.0.0.0/0" ];
              endpoint = "frwgq.duckdns.org:443";
              # endpoint = "68.237.124.182:51628";
              persistentKeepalive = 25;
            }
          ];
        };
      };
      fileSystems = {
        "/" = {
          device = "/dev/disk/by-uuid/576fdcd4-d642-4229-9073-90724eb72043";
          fsType = "btrfs";
          options = [
            "subvol=@"
            "compress=zstd:4"
            "ssd"
            "relatime"
            "discard=async"
          ];
        };
        "/home" = {
          device = "/dev/disk/by-uuid/576fdcd4-d642-4229-9073-90724eb72043";
          fsType = "btrfs";
          options = [
            "subvol=@home"
            "compress=zstd:4"
            "ssd"
            "relatime"
            "discard=async"
          ];
        };
        # "/home/tunnel/Music/Library" = {
        #   device = "/dev/disk/by-uuid/576fdcd4-d642-4229-9073-90724eb72043";
        #   fsType = "btrfs";
        #   options = [
        #     "subvol=@music"
        #     "compress=zstd:4"
        #     "ssd"
        #     "relatime"
        #     "discard=async"
        #   ];
        # };
        "/home/tunnel/tmp" = {
          device = "none";
          fsType = "tmpfs";
          options = [
            "defaults"
            "size=2G"
            "mode=755"
            "noatime"
            "nosuid"
            "nodev"
            "noexec"
            "mode=1777"
          ];
        };
        "/boot" = {
          device = "/dev/disk/by-uuid/78C1-6430";
          fsType = "vfat";
        };
      };

      swapDevices = [ { device = "/swap/swapfile"; } ];

      # Enables DHCP on each ethernet and wireless interface. In case of scripted networking
      # (the default) this is the recommended approach. When using systemd-networkd it's
      # still possible to use this option, but it's recommended to use it in conjunction
      # with explicit per-interface declarations with `networking.interfaces.<interface>.useDHCP`.
      # networking.interfaces.wlp2s0.useDHCP = lib.mkDefault true;

      nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
      hardware = {
        # cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
        graphics.extraPackages = [
          pkgs.intel-media-driver
          pkgs.libvdpau-va-gl
        ];
      };
    };
}

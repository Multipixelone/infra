{ inputs, ... }:
{
  flake-file.inputs.quadlet-nix.url = "github:SEIAROTg/quadlet-nix";

  flake.modules.homeManager.base = {
    imports = [
      inputs.quadlet-nix.homeManagerModules.quadlet
    ];
  };
  flake.modules.nixos.base =
    { pkgs, ... }:
    {
      imports = [ inputs.quadlet-nix.nixosModules.quadlet ];
      virtualisation = {
        quadlet.enable = true;
        containers.storage.settings.storage = {
          driver = "overlay";
        };
        libvirtd = {
          enable = true;
          onBoot = "ignore";
          onShutdown = "shutdown";
          qemu = {
            package = pkgs.qemu_kvm;
            # runAsRoot = true;
            swtpm.enable = true;
          };
        };
      };
      boot.initrd = {
        availableKernelModules = [
          "virtio_net"
          "virtio_pci"
          "virtio_mmio"
          "virtio_blk"
          "virtio_scsi"
        ];
        kernelModules = [
          "virtio_balloon"
          "virtio_console"
          "virtio_rng"
        ];
      };
    };
}

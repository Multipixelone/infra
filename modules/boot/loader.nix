{ lib, ... }:
{
  flake.modules.nixos.pc = {
    stylix.targets = {
      grub.enable = false;
      limine.enable = false;
      plymouth.enable = false;
    };
  };
  flake.modules.nixos.base =
    { pkgs, ... }:
    {
      boot = {
        loader.limine = {
          enable = lib.mkDefault true;
          panicOnChecksumMismatch = true;
          style.wallpapers = [ ];
          additionalFiles = {
            "efi/memtest86+/memtest.efi" = "${pkgs.memtest86plus}/mt86plus.efi";
          };
          extraEntries = ''
            /Memtest86+
            	protocol: chainload
            	path: boot():///efi/memtest86+/memtest.efi
          '';
        };
        loader.grub = {
          enable = lib.mkDefault false;
          efiSupport = true;
          device = "nodev";
          # gfxmodeEfi = "3440x1440";
          # lib.mkForce font = true;
          # timeoutStyle = "hidden";
        };
        consoleLogLevel = 0;
        initrd.verbose = false;
        # hide os choice
        loader.timeout = lib.mkDefault 3;
        kernelPackages = lib.mkDefault pkgs.linuxPackages_zen;
      };
    };
}

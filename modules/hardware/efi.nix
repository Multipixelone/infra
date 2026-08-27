{
  flake.modules = {
    nixos.efi.boot.loader = {
      efi.canTouchEfiVariables = true;
      grub.efiSupport = true;
    };

    homeManager.base =
      { pkgs, lib, ... }:
      {
        # EFI tooling is Linux-only.
        home.packages = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          pkgs.efivar
          pkgs.efibootmgr
        ];
      };
  };
}

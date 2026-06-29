{
  configurations.darwin.fi.module = {
    # NixOS-as-QEMU micro-VM so the Mac natively builds the repo's Linux
    # packages/wrappers (aarch64-linux via HVF fast; x86_64-linux via TCG slow)
    # instead of relying on ARM CI runners. Routes via an ssh-ng build-machine
    # at builder@localhost:31022.
    #
    # This is Determinate's port of nix-darwin's `nix.linux-builder` (the same
    # Nixpkgs darwin.linux-builder VM); nix-darwin's own block can't be used
    # because it asserts `nix.enable`, which Determinate forces off. Determinate
    # also ships a native (Virtualization.framework) Linux builder, but this VM
    # keeps the existing tuning verbatim.
    determinateNix.nixosVmBasedLinuxBuilder = {
      enable = true;
      ephemeral = true;
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      config =
        { ... }:
        {
          virtualisation = {
            cores = 6;
            darwin-builder = {
              diskSize = 40 * 1024;
              memorySize = 8 * 1024;
            };
          };
        };
    };
  };
}

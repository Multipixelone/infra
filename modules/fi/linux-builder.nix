{
  configurations.darwin.fi.module = {
    # NixOS-as-QEMU micro-VM so the Mac natively builds the repo's Linux
    # packages/wrappers (aarch64-linux via HVF fast; x86_64-linux via TCG slow)
    # instead of relying on ARM CI runners. Routes via ssh-ng build-machine
    # at linux-builder@localhost:31022.
    nix.linux-builder = {
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

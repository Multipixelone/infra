_: {
  flake.modules.nixos.pc =
    { pkgs, ... }:
    {
      networking.firewall.trustedInterfaces = [ "virbr0" ];
      programs.virt-manager.enable = true;
      environment.systemPackages = [ pkgs.distrobox ];
    };
}

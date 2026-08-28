{
  configurations.nixos.iso.module =
    { pkgs, ... }:
    {
      # No `facter.reportPath` here: this ISO is portable recovery media and
      # must not carry any one machine's hardware report. It previously shipped
      # link's report, which pinned AMD microcode and forced amdgpu into the
      # initrd on whatever box the stick was booted on. The architecture is an
      # inventory fact, so declare only that.
      facter.report.system = "x86_64-linux";
      environment.systemPackages = [
        pkgs.nixos-facter
      ];
    };
}

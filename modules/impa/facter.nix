{
  # The architecture is an inventory fact, not a machine-discovered hardware
  # identifier. Replace this minimal bootstrap report with nixos-facter output
  # after the physical host is available.
  configurations.nixos.impa.module.facter.report.system = "x86_64-linux";
}

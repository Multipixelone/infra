{ ... }:
{
  configurations.nixos.link.module =
    { config, pkgs, ... }:
    {
      boot = {
        # The in-tree driver in 7.2.7-zen1 lacks IT8688 support. The newer
        # upstream also fixes Gigabyte firmware overriding manual PWM writes.
        kernelPackages = pkgs.linuxPackages_zen.extend (
          _: previous: {
            it87 = previous.it87.overrideAttrs {
              name = "it87-unstable-2026-08-25-${previous.kernel.version}";
              version = "unstable-2026-08-25";
              src = pkgs.fetchFromGitHub {
                owner = "frankcrawford";
                repo = "it87";
                rev = "c567739c639533177abd66894a6a8d561337285f";
                hash = "sha256-MvaqqiwUA15lqJXgRapABqSUrOfeP9bkEdb7IEZuUOE=";
              };
            };
          }
        );
        extraModulePackages = [ config.boot.kernelPackages.it87 ];
        kernelModules = [ "it87" ];
        # Keep detection authoritative: no force_id or polarity correction.
        # MMIO enables upstream's DMI/SIV-gated Gigabyte control workarounds.
        # rgb.nix already supplies acpi_enforce_resources=lax.
        extraModprobeConfig = ''
          options it87 mmio=1
        '';
      };
    };
}

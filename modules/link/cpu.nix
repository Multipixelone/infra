{ lib, ... }:
{
  configurations.nixos.link.module =
    { pkgs, ... }:
    {
      options.link.cpu.threads = lib.mkOption {
        type = lib.types.ints.positive;
        default = 32;
        description = "Logical CPU capacity used to size link's worker budgets; does not limit online CPUs.";
      };
      config = {
        # Override the shared desktop module's performance policy on link.
        powerManagement.cpuFreqGovernor = lib.mkForce "powersave";
        services.power-profiles-daemon.enable = false;
        services.auto-cpufreq.enable = false;
        services.ucodenix = {
          enable = true;
          # Let the kernel select the replacement CPU's stepping at early boot.
          cpuModelId = "auto";
        };
        systemd.services.link-cpu-idle-policy = {
          description = "Restore balanced AMD EPP after boot or GameMode";
          requires = [ "cpufreq.service" ];
          after = [ "cpufreq.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            # Each GameMode end must execute the helper again.
            RemainAfterExit = false;
            ExecStart = lib.getExe (
              pkgs.writeShellApplication {
                name = "link-cpu-idle-policy";
                text = import ../../lib/link-cpu-idle-policy.nix;
              }
            );
          };
        };
      };
    };
}

{ ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      checks.link-cpu-policy =
        pkgs.runCommand "link-cpu-policy-check"
          {
            nativeBuildInputs = [
              pkgs.python3
              pkgs.bash
              pkgs.coreutils
              pkgs.gawk
            ];
          }
          ''
            export PYTHONDONTWRITEBYTECODE=1
            python3 ${./tests/cpu_policy_test.py} ${../../lib/link-ci-cpus.nix} ${../../lib/link-cpu-idle-policy.nix}
            touch "$out"
          '';
    };
}

{
  lib,
  rootPath,
  withSystem,
  ...
}:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (lib.hasSuffix "-linux" system) (
      let
        agent-run-long = pkgs.callPackage "${rootPath}/pkgs/agent-run-long" { };
      in
      {
        packages.agent-run-long = agent-run-long;
        checks.agent-run-long =
          pkgs.runCommand "agent-run-long-check" { nativeBuildInputs = [ pkgs.python3 ]; }
            ''
              python "${rootPath}/pkgs/agent-run-long/tests.py" "${agent-run-long}/bin/agent-run-long"
              touch "$out"
            '';
      }
    );

  flake.modules.homeManager.base =
    { pkgs, ... }:
    {
      home.packages = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        (withSystem pkgs.stdenv.hostPlatform.system ({ config, ... }: config.packages.agent-run-long))
      ];
    };
}

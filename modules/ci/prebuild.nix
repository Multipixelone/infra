{ config, lib, ... }:
let
  cfg = config.linkCache;
  ci = import ../../lib/ci.nix { inherit lib; };
  settings = {
    inherit (cfg) enable publicKey;
    inherit (ci.prebuild) hosts deployBranch;
    repository = "${config.flake.meta.owner.username}/${config.flake.meta.repo.name}";
    defaultBranch = config.flake.meta.repo.defaultBranch;
    domain = "git.finnrut.is";
    actor = config.flake.meta.owner.username;
    remote = "https://git.finnrut.is/${config.flake.meta.owner.username}/${config.flake.meta.repo.name}.git";
    cache = "https://link-cache.home.finnrut.is:5050";
    state = "/var/lib/forgejo-runner/link/prebuild";
  };
in
{
  perSystem = { pkgs, system, ... }: {
    packages.link-prebuild = pkgs.writeShellApplication {
      name = "link-prebuild";
      meta.description = "Prepare persistent verified Link closures and lease-promote the deploy ref";
      runtimeInputs = [
        pkgs.python3
        pkgs.git
        pkgs.nixVersions.latest
        pkgs.cacert
      ];
      # checkSystem names the controller check prepare requires as evidence.
      text = ''
        export SSL_CERT_FILE="''${SSL_CERT_FILE:-${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt}"
        exec python3 ${../../lib/link-prebuild.py} --config ${
          pkgs.writeText "link-prebuild-config.json" (builtins.toJSON (settings // { checkSystem = system; }))
        } "$@"
      '';
    };
    checks.link-prebuild =
      pkgs.runCommand "link-prebuild-offline-tests"
        {
          nativeBuildInputs = [
            pkgs.python3
            pkgs.git
          ];
        }
        ''
          export PYTHONDONTWRITEBYTECODE=1
          python3 ${./tests/prebuild_test.py} ${../../lib/link-prebuild.py}
          touch "$out"
        '';
  };
}

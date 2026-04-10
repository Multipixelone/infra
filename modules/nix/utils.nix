{ withSystem, config, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.system = pkgs.writeShellScriptBin "system" "nix-instantiate --eval --expr builtins.currentSystem --raw";
    };
  flake.modules.homeManager.base =
    { pkgs, ... }:
    {
      home.packages =
        (with pkgs; [
          nix-output-monitor
          nix-fast-build
          nix-tree
          nvd
          nix-diff
        ])
        ++ [
          (withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.system))
        ];
    };
  flake.modules.nixos.base =
    { lib, ... }:
    {
      environment.variables.NH_FLAKE = lib.mkDefault "/home/${config.flake.meta.owner.username}/Documents/Git/${config.flake.meta.repo.name}";
      programs.nh = {
        enable = true;
        clean = {
          enable = true;
          extraArgs = "--keep-since 30d --keep 10";
        };
      };
    };
}

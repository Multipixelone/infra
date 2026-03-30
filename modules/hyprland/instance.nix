{ withSystem, ... }:
{
  perSystem =
    { pkgs, inputs', ... }:
    {
      packages.hyprctl-instance = pkgs.writeShellApplication {
        name = "hyprctl-instance";
        runtimeInputs = [
          pkgs.coreutils
          inputs'.hyprland.packages.hyprland
          pkgs.jq
        ];
        text = ''
          XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
          HYPRLAND_INSTANCE_SIGNATURE=$(hyprctl instances -j 2>/dev/null | jq -r 'sort_by(.time) | last | .instance')
          export HYPRLAND_INSTANCE_SIGNATURE
          echo "$HYPRLAND_INSTANCE_SIGNATURE"
        '';
      };
    };
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    let
      hyprctl-instance = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.hyprctl-instance
      );
    in
    {
      home.packages = [
        hyprctl-instance
      ];
    };
}

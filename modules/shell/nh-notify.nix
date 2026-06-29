{ withSystem, ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      inherit (pkgs.writers) writeFishBin;
      notify-send = lib.getExe' pkgs.libnotify "notify-send";
      icon = "${pkgs.papirus-icon-theme}/share/icons/Papirus/64x64/apps/system-software-update.svg";
      nh-notify =
        name: word:
        writeFishBin name ''
          nh os ${word} $argv \
            && ${notify-send} "nixos-rebuild" "Rebuild complete" \
                --app-name nixos-rebuild \
                --icon ${icon}
        '';
    in
    {
      packages.genswitch = nh-notify "genswitch" "switch";
      packages.gentest = nh-notify "gentest" "test";
    };
  flake.modules.homeManager.base =
    { pkgs, lib, ... }:
    {
      # `nh os switch/test` wrappers (with a Linux icon-theme notify icon) are
      # NixOS rebuild helpers — Linux-only.
      home.packages = lib.optionals pkgs.stdenv.isLinux (
        withSystem pkgs.stdenv.hostPlatform.system (
          { config, ... }:
          let
            ps = config.packages;
          in
          [
            ps.genswitch
            ps.gentest
          ]
        )
      );
    };
}

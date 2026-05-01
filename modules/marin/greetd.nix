{
  lib,
  config,
  rootPath,
  withSystem,
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.transparent-cursor-theme = pkgs.callPackage "${rootPath}/pkgs/transparent-cursor" { };
    };

  configurations.nixos.marin.module =
    { pkgs, ... }:
    let
      cage = lib.getExe pkgs.cage;
      foot = lib.getExe (
        withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.foot)
      );
      pragmata = withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.pragmata);
      transparentCursorTheme = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.transparent-cursor-theme
      );
      xcursorPath = "${transparentCursorTheme}/share/icons";
    in
    {
      fonts = {
        enableDefaultPackages = false;
        packages = [
          pkgs.ipafont
          pragmata
        ];
        fontconfig.defaultFonts.monospace = [
          "PragmataPro Mono Liga"
          "IPAGothic"
        ];
      };
      services.greetd = {
        enable = true;
        settings = {
          initial_session = {
            command = "${cage} -s -- env XCURSOR_PATH=${xcursorPath} XCURSOR_THEME=Transparent XCURSOR_SIZE=1 ${foot} -a rmpc -f \"PragmataPro Mono Liga:size=24\" rmpc";
            user = config.flake.meta.owner.username;
          };
          default_session = {
            command = "${cage} -s -- env XCURSOR_PATH=${xcursorPath} XCURSOR_THEME=Transparent XCURSOR_SIZE=1 ${foot} -a rmpc -f \"PragmataPro Mono Liga:size=24\" rmpc";
            user = config.flake.meta.owner.username;
          };
        };
      };

      # Avoid TTY1 racing with greetd for the active console.
      systemd.services."getty@tty1".enable = false;
      systemd.services."autovt@tty1".enable = false;
    };
}

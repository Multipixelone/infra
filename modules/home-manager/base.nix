{ config, lib, ... }:
{
  flake.modules.homeManager.base =
    { pkgs, ... }:
    {
      home = {
        username = config.flake.meta.owner.username;
        homeDirectory = lib.mkDefault "/home/${config.flake.meta.owner.username}";
        extraOutputsToInstall = [
          "doc"
          "devdoc"
        ];
      };
      # `.face` is a Linux account-picture convention (AccountsService / display
      # managers); meaningless on macOS, so skip it on darwin.
      home.file = lib.mkIf pkgs.stdenv.isLinux { ".face".source = ../Finn.jpg; };
      programs.home-manager.enable = true;
      dconf.enable = lib.mkDefault false;
      systemd.user.startServices = lib.mkDefault "sd-switch";
    };
}

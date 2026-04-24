{ config, lib, ... }:
{
  flake.modules.homeManager.base = _args: {
    home = {
      username = config.flake.meta.owner.username;
      homeDirectory = lib.mkDefault "/home/${config.flake.meta.owner.username}";
      extraOutputsToInstall = [
        "doc"
        "devdoc"
      ];
    };
    home.file.".face".source = ../Finn.jpg;
    programs.home-manager.enable = true;
    dconf.enable = lib.mkDefault false;
    systemd.user.startServices = lib.mkDefault "sd-switch";
  };
}

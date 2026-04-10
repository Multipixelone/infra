{ config, ... }:
{
  flake.modules.homeManager.base = _args: {
    home = {
      username = config.flake.meta.owner.username;
      homeDirectory = "/home/${config.flake.meta.owner.username}";
      extraOutputsToInstall = [
        "doc"
        "devdoc"
      ];
    };
    home.file.".face".source = ../Finn.jpg;
    programs.home-manager.enable = true;
    systemd.user.startServices = "sd-switch";
  };
}

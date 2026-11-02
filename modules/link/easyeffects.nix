{ config, ... }:
{
  # link: keep EasyEffects installed with its presets, but do not start it
  # with the graphical session. Start manually via the app or
  # `systemctl --user start easyeffects`.
  configurations.nixos.link.module.home-manager.users.${config.flake.meta.owner.username} =
    { lib, ... }:
    {
      systemd.user.services.easyeffects.Install.WantedBy = lib.mkForce [ ];
    };
}

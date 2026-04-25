{ config, lib, ... }:
let
  home = "/var/services/homes/${config.flake.meta.owner.username}";
in
{
  configurations.homeManager.alexandria = {
    system = "x86_64-linux";
    module = {
      home = {
        homeDirectory = home;
        stateVersion = "25.05";
      };

      # DSM has no `systemd --user` session / user DBus bus.
      # sd-switch would fail at activation trying to talk to it.
      systemd.user.startServices = false;

      # atuin daemon.enable creates a systemd user service;
      # on DSM there's no systemd --user. autostart=true in
      # settings means atuin manages its own daemon lifecycle.
      programs.atuin.daemon.enable = lib.mkForce false;
      programs.atuin.settings.daemon.enabled = true;

      # DSM has no terminal multiplexer use-case; zellij's fish hooks
      # (rename-tab, switch-mode) hang on every command over SSH.
      programs.zellij.enable = lib.mkForce false;

      # agenix decrypt paths — base pulls in many age.secrets via recursive
      # imports; all default to /home/tunnel/... which doesn't exist on DSM.
      age = {
        identityPaths = lib.mkForce [ "${home}/.ssh/agenix" ];
        secretsDir = lib.mkForce "${home}/.secrets";
      };

    };
  };
}

{
  config,
  inputs,
  lib,
  ...
}:
{
  flake.modules.darwin.base = {
    imports = [ inputs.home-manager.darwinModules.home-manager ];

    home-manager = {
      useGlobalPkgs = true;
      # works on darwin (unlike NixOS issue #6770)
      useUserPackages = true;
      extraSpecialArgs.hasGlobalPkgs = true;
      extraSpecialArgs.hosts = config.hosts;
      backupFileExtension = "bkp";

      users.${config.flake.meta.owner.username} = {
        imports = [
          # darwin's system.stateVersion is an integer (6); HM wants a string.
          # Pin the HM stateVersion explicitly rather than copying osConfig.
          { home.stateVersion = "25.11"; }
          config.flake.modules.homeManager.base
        ];

        # base sets homeDirectory via mkDefault /home/<user>; macOS lives in /Users.
        home.homeDirectory = lib.mkForce "/Users/${config.flake.meta.owner.username}";

        # No `systemd --user` on darwin; sd-switch would fail at activation.
        systemd.user.startServices = lib.mkForce false;

        # secrets.nix hardcodes agenix paths under /home/tunnel; macOS is /Users.
        age = {
          identityPaths = lib.mkForce [
            "/Users/${config.flake.meta.owner.username}/.ssh/agenix"
          ];
          secretsDir = lib.mkForce "/Users/${config.flake.meta.owner.username}/.secrets";
        };

        # stylix HM modules add nixpkgs.overlays unconditionally, but with
        # useGlobalPkgs they're already at system level — silence the warning.
        nixpkgs.overlays = lib.mkForce null;
      };
    };
  };
}

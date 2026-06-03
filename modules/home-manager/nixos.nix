{
  config,
  inputs,
  lib,
  ...
}:
{
  flake.modules.nixos = {
    base = {
      imports = [ inputs.home-manager.nixosModules.home-manager ];

      home-manager = {
        useGlobalPkgs = true;
        extraSpecialArgs.hasGlobalPkgs = true;
        extraSpecialArgs.hosts = config.hosts;
        backupFileExtension = "bkp";
        # https://github.com/nix-community/home-manager/issues/6770
        #useUserPackages = true;

        users.${config.flake.meta.owner.username} = {
          imports = [
            (
              { osConfig, ... }:
              {
                home.stateVersion = osConfig.system.stateVersion;
              }
            )
            config.flake.modules.homeManager.base
          ];

          # stylix HM modules add nixpkgs.overlays unconditionally,
          # but with useGlobalPkgs=true they're already at NixOS level
          # and the HM-level ones are non-functional. Silence the warning.
          nixpkgs.overlays = lib.mkForce null;
        };
      };
    };
    pc = {
      home-manager.users.${config.flake.meta.owner.username} = {
        dconf.enable = true;
        imports = [
          config.flake.modules.homeManager.gui
          config.flake.modules.homeManager.media
        ];
      };
    };
    laptop = {
      home-manager.users.${config.flake.meta.owner.username}.imports = [
        config.flake.modules.homeManager.laptop
      ];
    };
    gaming = {
      home-manager.users.${config.flake.meta.owner.username}.imports = [
        config.flake.modules.homeManager.gaming
      ];
    };
    media = {
      home-manager.users.${config.flake.meta.owner.username}.imports = [
        config.flake.modules.homeManager.media
      ];
    };
  };
}

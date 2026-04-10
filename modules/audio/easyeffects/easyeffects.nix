_: {
  flake.modules.nixos.pc.programs.dconf.enable = true;
  flake.modules.homeManager.gui = {
    services.easyeffects.enable = true;
    # import presets
    xdg.dataFile."easyeffects/output" = {
      source = ./presets;
      recursive = true;
    };
  };
}

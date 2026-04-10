{
  flake.modules.homeManager.base =
    hmArgs@{
      pkgs,
      ...
    }:
    {
      home.packages = with pkgs; [
        grc
      ];
      programs = {
        zoxide.enable = true;
        dircolors = {
          enable = true;
        };
        eza = {
          inherit (hmArgs.config.home.shell) enableFishIntegration;
          enable = true;
          git = true;
          icons = "auto";
          extraOptions = [
            "--color=auto"
          ];
        };
      };
    };
}

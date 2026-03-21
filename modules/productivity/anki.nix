{
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    {
      programs.anki = {
        enable = true;
        package = pkgs.anki;
        reduceMotion = true;
        minimalistMode = true;

        profiles."User 1".sync = {
          syncMedia = true;
          autoSync = true;
        };

        theme = "dark";
        style = "native";

        videoDriver = "opengl";

        hideTopBar = true;
        hideTopBarMode = "fullscreen";
        hideBottomBar = true;
        hideBottomBarMode = "fullscreen";

        spacebarRatesCard = true;

        answerKeys = [
          {
            ease = 1;
            key = "down";
          } # Again
          {
            ease = 2;
            key = "left";
          } # Hard
          {
            ease = 3;
            key = "right";
          } # Good
          {
            ease = 4;
            key = "up";
          } # Easy
        ];

        addons = with pkgs.ankiAddons; [
          review-heatmap
          anki-connect
        ];
      };
    };
}

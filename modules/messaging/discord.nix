{
  inputs,
  ...
}:
{
  flake-file.inputs.nixcord.url = "github:ScarsTRF/nixcord/pnpmFix";

  nixpkgs.config.allowUnfreePackages = [ "discord" ];
  flake.modules.homeManager.gui = {
    imports = [
      inputs.nixcord.homeModules.nixcord
    ];
    programs.nixcord = {
      enable = true;
      discord.vencord.enable = false;
      discord.equicord.enable = true;
      config = {
        frameless = true;
        themeLinks = [
          "https://catppuccin.github.io/discord/dist/catppuccin-mocha-mauve.theme.css"
        ];
        plugins = {
          petpet.enable = true;
          readAllNotificationsButton.enable = true;
          spotifyCrack.enable = true;
          whoReacted.enable = true;
          youtubeAdblock.enable = true;
          webScreenShareFixes.enable = true;
          questify = {
            enable = true;
            # completeAchievementQuestsInBackground = true;
            # completeGameQuestsInBackground = true;
            # completeVideoQuestsInBackground = true;
          };
        };
      };
    };
  };
}

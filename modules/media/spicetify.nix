{
  inputs,
  ...
}:
{
  flake-file.inputs.spicetify-nix = {
    url = "github:Gerg-L/spicetify-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  nixpkgs.config.allowUnfreePackages = [ "spotify" ];
  flake.modules.homeManager.gui = {
    # themable spotify
    imports = [
      inputs.spicetify-nix.homeManagerModules.default
    ];
    stylix.targets.spicetify.enable = false;

    programs.spicetify =
      { pkgs, ... }:
      let
        spicePkgs = inputs.spicetify-nix.legacyPackages.${pkgs.stdenv.hostPlatform.system};
      in
      {
        enable = true;

        theme = spicePkgs.themes.dribbblish;
        colorScheme = "catppuccin-mocha";

        enabledCustomApps = with spicePkgs.apps; [
          lyricsPlus
          newReleases
        ];

        enabledExtensions = with spicePkgs.extensions; [
          powerBar
          # addToQueueTop
          fullAppDisplayMod
          history
          hidePodcasts
          shuffle
          playlistIcons
        ];
      };
  };
}
